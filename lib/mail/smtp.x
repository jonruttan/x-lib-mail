; smtp.x -- Smtp: the Simple Mail Transfer Protocol (RFC 5321), client and server.
;
; Both sides talk over a mail/wire wire: a socket, TLS on a socket, or a
; script that runs either side with no network.  STARTTLS (RFC 3207) turns a
; socket's wire into a TLS one in place.
;
; The client says EHLO (HELO where EHLO is refused), may take STARTTLS and
; AUTH (PLAIN or LOGIN, RFC 4954), and sends a message: MAIL, a RCPT a
; recipient, DATA with the text dot-stuffed and every line ended with CRLF.
; A reply is (CODE . LINES); one that is not what the step wants raises a
; label 'io with the reply as its data.
;
; The server runs one session on a wire to QUIT or the wire's end, and asks
; the caller's functions what to do: whether to take a recipient, whether a
; user's password is right, and what to do with a message.  Accepting
; connections, and a process for each, is the caller's.
(module mail/smtp)

(import x/core/doors char->int int+ int- int< int= obj-ref obj-set! str-byte-len str-byte-ref str-byte-sub)
(import x/type/vector)
(import x/type/assoc)
(import x/sys/socket)
(import x/codec/base64)
(import x/codec/bytes)
(import mail/message)
(import mail/wire)

(def %io (fn (_ what data) (Err raise (lit io) (Str8 append "Smtp: " what) data)))

(def %byte (fn (_ s i) (char->int (str-byte-ref s i))))

(def %opt (fn (_ key opts) (let ((p (Assoc find key opts))) (if (null? p) () (rest p)))))

(def %flag? (fn (_ key opts) (List any? (fn (_ o) (if (pair? o) (eq? (first o) key) #f)) opts)))

; --- replies

(def %digit (fn (_ c) (if (int< 47 c) (if (int< c 58) (int- c 48) ()) ())))

; A reply line's three-digit code, or nil.
(def %code
  (fn (_ line)
    (def a (%digit (%byte line 0)))
    (def b (%digit (%byte line 1)))
    (def c (%digit (%byte line 2)))
    (if (if (null? a) #t (if (null? b) #t (null? c))) () (int+ (* a 100) (int+ (* b 10) c)))))

; A reply: lines "CODE-text" up to one "CODE text", as (CODE . TEXTS).
(def %reply
  (fn (_ w)
    (let go ((acc ()))
      (let ((line (Wire read-line w)))
        (when (null? line) (%io "the connection closed before a reply" ()))
        (when (int< (str-byte-len line) 3) (%io "a reply line too short" line))
        (def code (%code line))
        (when (null? code) (%io "a reply line with no code" line))
        (def text (if (int< 4 (str-byte-len line)) (str-byte-sub line 4 (int- (str-byte-len line) 4)) ""))
        (if (if (int< 3 (str-byte-len line)) (int= (%byte line 3) 45) #f)
          (go (pair text acc))
          (pair code (List reverse (pair text acc))))))))

(def %class (fn (_ reply) (int- (first reply) (% (first reply) 100))))

(def %expect
  (fn (_ reply class what)
    (unless (int= (%class reply) class)
      (%io (Str8 append what ": " (Str8 str (first reply)) " " (Str8 join " " (rest reply))) reply))
    reply))

; --- the client
;
; A client session is a vector: 1 the wire, 2 the name it said hello with,
; 3 the extensions the server named, each (KEYWORD . PARAMS) with KEYWORD in
; upper case.

(def %session
  (fn (_ w)
    (def s (Vector make 3 0))
    (obj-set! s 1 w)
    (obj-set! s 2 ())
    (obj-set! s 3 ())
    s))

(def %extension
  (fn (_ line)
    (def words (List filter (fn (_ x) (int< 0 (str-byte-len x))) (Str8 split " " line)))
    (if (null? words) () (pair (Str8 upcase (first words)) (rest words)))))

; s's command line, and the reply
(def %ask
  (fn (_ s line)
    (Wire write-line (obj-ref s 1) line)
    (%reply (obj-ref s 1))))

; A message's text with CRLF line ends, ready for DATA: a line that starts
; with a dot has another put before it, and the text ends with ".".
(def %data-text
  (fn (_ text)
    (def lines (Str8 split "\n" (Str8 replace "\r\n" "\n" text)))
    (def body (if (if (null? lines) #f (Str8 =? (List last lines) "")) (List init lines) lines))
    (Str8 append
      (Str8 join "" (List map (fn (_ l) (Str8 append (if (Str8 starts? "." l) "." "") l "\r\n")) body))
      ".\r\n")))

; AUTH PLAIN's credential: NUL, the user, NUL, the password, in base64.
(def %plain
  (fn (_ user password)
    (def b (Bytes writer))
    (Bytes put-u8 b 0)
    (Bytes put b user)
    (Bytes put-u8 b 0)
    (Bytes put b password)
    (def r (Base64 encode-region (Bytes written b)))
    (str-byte-sub (first r) (first (rest r)) (first (rest (rest r))))))

; --- the server

; A command line's verb in upper case and the rest: (VERB . ARGUMENT).
(def %command
  (fn (_ line)
    (def sp (Str8 index-of " " line))
    (if (null? sp)
      (pair (Str8 upcase line) "")
      (pair (Str8 upcase (str-byte-sub line 0 sp)) (Str8 trim (str-byte-sub line (int+ sp 1) (int- (str-byte-len line) (int+ sp 1))))))))

; MAIL FROM:<a> or RCPT TO:<a>'s address, after the prefix in any case, and
; its parameters: (ADDRESS . PARAMS), or nil when it does not parse.
(def %path
  (fn (_ prefix arg)
    (if (if (int< (str-byte-len prefix) (int+ (str-byte-len arg) 1)) (Str8 ci=? prefix (str-byte-sub arg 0 (str-byte-len prefix))) #f)
      (let ((s (Str8 trim (str-byte-sub arg (str-byte-len prefix) (int- (str-byte-len arg) (str-byte-len prefix))))))
        (def lt (Str8 index-of "<" s))
        (def gt (Str8 index-of ">" s))
        (if (if (null? lt) #t (if (null? gt) #t (not (int= lt 0))))
          ()
          (pair (str-byte-sub s 1 (int- gt 1))
                (List filter (fn (_ x) (int< 0 (str-byte-len x))) (Str8 split " " (str-byte-sub s (int+ gt 1) (int- (str-byte-len s) (int+ gt 1))))))))
      ())))

(def %param-value
  (fn (_ params key)
    (let go ((l params))
      (match ((null? l) ())
             ((Str8 starts? (Str8 append key "=") (Str8 upcase (first l)))
               (str-byte-sub (first l) (int+ (str-byte-len key) 1) (int- (str-byte-len (first l)) (int+ (str-byte-len key) 1))))
             (#t (go (rest l)))))))

; The DATA lines up to the line holding a dot alone, dots taken off, as
; text with CRLF line ends, written into a Bytes writer: (OVER? . TEXT),
; OVER? #t where it passed limit (its lines are still read, and dropped).
(def %read-data
  (fn (_ w limit)
    (def b (Bytes writer))
    (let go ((over #f))
      (let ((line (Wire read-line w)))
        (match
          ((null? line) (%io "the connection closed in DATA" ()))
          ((Str8 =? line ".")
            (pair over (let ((r (Bytes written b))) (str-byte-sub (first r) 0 (first (rest (rest r)))))))
          (#t
            (let ((l (if (Str8 starts? "." line) (str-byte-sub line 1 (int- (str-byte-len line) 1)) line)))
              (if (if over #t (int< limit (int+ (Bytes size b) (int+ (str-byte-len l) 2))))
                (go #t)
                (do (Bytes put b l) (Bytes put b "\r\n") (go #f))))))))))

; AUTH PLAIN's credential decoded: (USER . PASSWORD), or nil.
(def %unplain
  (fn (_ b64)
    (def r (guard (_ ()) (Base64 decode-region b64)))
    (if (null? r) ()
      (let ((n (Bytes length r)))
        (def nul (fn (self i) (match ((int= i n) ()) ((int= (Bytes ref r i) 0) i) (#t (self (int+ i 1))))))
        (def a (nul 0))
        (def b (if (null? a) () (nul (int+ a 1))))
        (if (null? b) ()
          (pair (str-byte-sub (first r) (int+ a 1) (int- b (int+ a 1)))
                (str-byte-sub (first r) (int+ b 1) (int- n (int+ b 1)))))))))

(def %b64-text
  (fn (_ b64)
    (def r (guard (_ ()) (Base64 decode-region b64)))
    (if (null? r) () (str-byte-sub (first r) 0 (Bytes length r)))))

; One server session's state: a vector of 1 the wire, 2 the options, 3 the
; client's hello name or nil, 4 the sender or nil, 5 the recipients, newest
; first, 6 the user once authenticated, 7 #t at QUIT.
(def %state
  (fn (_ w opts)
    (def st (Vector make 7 0))
    (obj-set! st 1 w)
    (obj-set! st 2 opts)
    (obj-set! st 3 ())
    (obj-set! st 4 ())
    (obj-set! st 5 ())
    (obj-set! st 6 ())
    (obj-set! st 7 #f)
    st))

(def %say (fn (_ st code text) (Wire write-line (obj-ref st 1) (Str8 append (Str8 str code) " " text))))

(def %reset! (fn (_ st) (do (obj-set! st 4 ()) (obj-set! st 5 ()))))

(def %max-size (fn (_ opts) (let ((n (%opt (lit size) opts))) (if (null? n) 10485760 n))))

(def %tls-offered? (fn (_ st) (if (null? (%opt (lit pem) (obj-ref st 2))) #f (not (Wire tls? (obj-ref st 1))))))

(def %auth-offered?
  (fn (_ st)
    (def opts (obj-ref st 2))
    (if (null? (%opt (lit auth) opts)) #f
      (if (null? (obj-ref st 6))
        (if (Wire tls? (obj-ref st 1)) #t (%flag? (lit auth-in-clear) opts))
        #f))))

(def %ehlo
  (fn (_ st arg)
    (def name (let ((n (%opt (lit name) (obj-ref st 2)))) (if (null? n) "localhost" n)))
    (def lines
      (List filter (fn (_ l) (not (null? l)))
        (list (Str8 append name " hello " arg)
              "PIPELINING"
              (Str8 append "SIZE " (Str8 str (%max-size (obj-ref st 2))))
              "8BITMIME"
              (if (%tls-offered? st) "STARTTLS" ())
              (if (%auth-offered? st) "AUTH PLAIN LOGIN" ()))))
    (let go ((l lines))
      (if (null? (rest l))
        (%say st 250 (first l))
        (do (Wire write-line (obj-ref st 1) (Str8 append "250-" (first l))) (go (rest l)))))))

(def %authenticate
  (fn (_ st arg)
    (def check (%opt (lit auth) (obj-ref st 2)))
    (def w (obj-ref st 1))
    (def words (List filter (fn (_ x) (int< 0 (str-byte-len x))) (Str8 split " " arg)))
    (def mech (if (null? words) "" (Str8 upcase (first words))))
    (def ask (fn (_ prompt) (do (%say st 334 prompt) (Wire read-line w))))
    (def creds
      (match
        ((Str8 =? mech "PLAIN")
          (let ((b64 (if (null? (rest words)) (ask "") (first (rest words)))))
            (if (if (null? b64) #t (Str8 =? b64 "*")) (lit cancelled) (%unplain b64))))
        ((Str8 =? mech "LOGIN")
          (let ((u (ask "VXNlcm5hbWU6")))
            (if (if (null? u) #t (Str8 =? u "*")) (lit cancelled)
              (let ((p (ask "UGFzc3dvcmQ6")))
                (if (if (null? p) #t (Str8 =? p "*")) (lit cancelled)
                  (let ((user (%b64-text u)) (password (%b64-text p)))
                    (if (if (null? user) #t (null? password)) () (pair user password))))))))
        (#t (lit unknown))))
    (match
      ((eq? creds (lit unknown)) (%say st 504 "5.5.4 Unrecognized authentication type"))
      ((eq? creds (lit cancelled)) (%say st 501 "5.0.0 Authentication cancelled"))
      ((null? creds) (%say st 501 "5.5.2 Cannot decode the credentials"))
      ((check (first creds) (rest creds))
        (do (obj-set! st 6 (first creds)) (%say st 235 "2.7.0 Authentication successful")))
      (#t (%say st 535 "5.7.8 Authentication credentials invalid")))))

(def %mail
  (fn (_ st arg)
    (def p (%path "FROM:" arg))
    (def size (if (null? p) () (%param-value (rest p) "SIZE")))
    (match
      ((null? (obj-ref st 3)) (%say st 503 "5.5.1 Say hello first"))
      ((not (null? (obj-ref st 4))) (%say st 503 "5.5.1 Sender already given"))
      ((if (%flag? (lit require-auth) (obj-ref st 2)) (null? (obj-ref st 6)) #f) (%say st 530 "5.7.0 Authentication required"))
      ((null? p) (%say st 501 "5.5.4 Syntax: MAIL FROM:<address>"))
      ((if (null? size) #f (let ((n (guard (_ ()) (%str->number size)))) (if (null? n) #f (int< (%max-size (obj-ref st 2)) n))))
        (%say st 552 "5.3.4 Message size exceeds the limit"))
      (#t (do (obj-set! st 4 (first p)) (%say st 250 "2.1.0 OK"))))))

(def %rcpt
  (fn (_ st arg)
    (def p (%path "TO:" arg))
    (def take (%opt (lit rcpt) (obj-ref st 2)))
    (match
      ((null? (obj-ref st 4)) (%say st 503 "5.5.1 Need MAIL first"))
      ((null? p) (%say st 501 "5.5.4 Syntax: RCPT TO:<address>"))
      ((int< 99 (List length (obj-ref st 5))) (%say st 452 "4.5.3 Too many recipients"))
      ((if (null? take) #t (take (first p) (obj-ref st 6)))
        (do (obj-set! st 5 (pair (first p) (obj-ref st 5))) (%say st 250 "2.1.5 OK")))
      (#t (%say st 550 "5.1.1 No such recipient here")))))

(def %info
  (fn (_ st)
    (list (pair (lit hello) (obj-ref st 3)) (pair (lit tls) (Wire tls? (obj-ref st 1))) (pair (lit user) (obj-ref st 6)))))

(def %data
  (fn (_ st)
    (def deliver (%opt (lit deliver) (obj-ref st 2)))
    (match
      ((null? (obj-ref st 4)) (%say st 503 "5.5.1 Need MAIL first"))
      ((null? (obj-ref st 5)) (%say st 503 "5.5.1 Need RCPT first"))
      (#t
        (do (%say st 354 "End data with <CR><LF>.<CR><LF>")
            (let ((got (%read-data (obj-ref st 1) (%max-size (obj-ref st 2)))))
              (match
                ((first got) (%say st 552 "5.3.4 Message size exceeds the limit"))
                ((null? deliver) (%say st 250 "2.0.0 OK"))
                ((guard (_ #f) (do (deliver (obj-ref st 4) (List reverse (obj-ref st 5)) (rest got) (%info st)) #t))
                  (%say st 250 "2.0.0 OK"))
                (#t (%say st 451 "4.3.0 The message could not be delivered"))))
            (%reset! st)
            (Heap collect))))))

(def %starttls
  (fn (_ st)
    (if (%tls-offered? st)
      (do (%say st 220 "2.0.0 Ready to start TLS")
          (Wire tls-accept (obj-ref st 1) (%opt (lit pem) (obj-ref st 2)))
          (obj-set! st 3 ())
          (%reset! st))
      (%say st 502 "5.5.1 STARTTLS not offered"))))

(def %serve-line
  (fn (_ st line)
    (def c (%command line))
    (def verb (first c))
    (def arg (rest c))
    (match
      ((int< 512 (str-byte-len line)) (%say st 500 "5.5.2 Line too long"))
      ((if (Str8 =? verb "EHLO") #t (Str8 =? verb "HELO"))
        (if (Str8 =? arg "") (%say st 501 "5.5.4 Say who you are")
          (do (obj-set! st 3 arg)
              (%reset! st)
              (if (Str8 =? verb "EHLO") (%ehlo st arg)
                (%say st 250 (let ((n (%opt (lit name) (obj-ref st 2)))) (if (null? n) "localhost" n)))))))
      ((Str8 =? verb "MAIL") (%mail st arg))
      ((Str8 =? verb "RCPT") (%rcpt st arg))
      ((Str8 =? verb "DATA") (%data st))
      ((Str8 =? verb "RSET") (do (%reset! st) (%say st 250 "2.0.0 OK")))
      ((Str8 =? verb "NOOP") (%say st 250 "2.0.0 OK"))
      ((Str8 =? verb "VRFY") (%say st 252 "2.5.0 Cannot verify, but will try"))
      ((Str8 =? verb "QUIT") (do (%say st 221 "2.0.0 Bye") (obj-set! st 7 #t)))
      ((Str8 =? verb "STARTTLS") (%starttls st))
      ((Str8 =? verb "AUTH")
        (match ((null? (obj-ref st 3)) (%say st 503 "5.5.1 Say hello first"))
               ((not (%auth-offered? st)) (%say st 503 "5.5.1 AUTH not offered"))
               ((not (null? (obj-ref st 4))) (%say st 503 "5.5.1 Not during a transaction"))
               (#t (%authenticate st arg))))
      (#t (%say st 500 "5.5.2 Command not recognized")))))

(def-class Smtp ()
  (doc "SMTP (RFC 5321) over a wire: a socket, TLS on a socket, or a script. The client says hello, may take STARTTLS and AUTH, and sends messages; the server runs one session, asking the caller's functions which recipients to take and what to do with each message."
    (example "(Wire output (Smtp serve (Wire script \"QUIT\\r\\n\") ()))" "\"220 localhost ESMTP\\r\\n221 2.0.0 Bye\\r\\n\"")
    (see connect send serve))
  (static
    ; --- the client
    (method client (self (param w VECTOR "A wire to a server"))
      (doc "A client session on the wire, once the server's 220 greeting is read; any other greeting raises a label 'io."
        (returns VECTOR "A session")
        (example "(null? (Smtp extensions (Smtp client (Wire script \"220 mx ESMTP\\r\\n\"))))" "#t"))
      (%expect (%reply w) 200 "the greeting")
      (%session w))

    (method connect (self (param host STRING "A host name or dotted quad")
                          (param port INTEGER "Usually 25, 587, or 465 for TLS from the start")
                          . (param opts ALIST "('tls) for TLS from the start; (host . NAME), the name TLS checks; ('insecure) to skip that check"))
      (doc "A client session to host:port, under TLS from the start with ('tls), once the server's greeting is read. A failure raises a label 'io."
        (returns VECTOR "A session")
        (sample "(Smtp connect \"127.0.0.1\" 25)" "a session"))
      (def quad (Socket resolve host))
      (def w (Wire socket (Socket tcp-connect quad port)))
      (when (%flag? (lit tls) opts) (Wire tls-connect w (%tls-opts host opts)))
      (self client w))

    (method wire (self (param s VECTOR "A client session"))
      (doc "The session's wire: for Wire output on a script, or Wire tls? and the like."
        (returns VECTOR "A wire")
        (example "(Wire output (Smtp wire (Smtp client (Wire script \"220 mx\\r\\n\"))))" "\"\""))
      (obj-ref s 1))

    (method command (self (param s VECTOR "A client session") (param line STRING "A command line, without its line end"))
      (doc "Send one command and answer the server's reply as it came."
        (returns LIST "(CODE . TEXTS)")
        (example "(Smtp command (Smtp client (Wire script \"220 mx\\r\\n250 OK\\r\\n\")) \"NOOP\")" "(250 \"OK\")"))
      (%ask s line))

    (method hello (self (param s VECTOR "A client session") (param name STRING "This host's name"))
      (doc "EHLO, or HELO where the server refuses EHLO. Answers the extensions the server named, each (KEYWORD . PARAMS), KEYWORD in upper case; HELO names none."
        (returns LIST "(KEYWORD . PARAMS) pairs")
        (example "(Smtp hello (Smtp client (Wire script \"220 mx\\r\\n250-mx hi\\r\\n250-SIZE 1000\\r\\n250 starttls\\r\\n\")) \"me\")" "((\"SIZE\" \"1000\") (\"STARTTLS\"))"))
      (def r (%ask s (Str8 append "EHLO " name)))
      (def exts
        (if (int= (%class r) 200)
          (List filter (fn (_ e) (not (null? e))) (List map %extension (if (null? (rest r)) () (rest (rest r)))))
          (do (%expect (%ask s (Str8 append "HELO " name)) 200 "HELO") ())))
      (obj-set! s 2 name)
      (obj-set! s 3 exts)
      exts)

    (method extensions (self (param s VECTOR "A client session"))
      (doc "The extensions the server named at the last hello, each (KEYWORD . PARAMS)."
        (returns LIST "(KEYWORD . PARAMS) pairs")
        (example "(null? (Smtp extensions (Smtp client (Wire script \"220 mx\\r\\n\"))))" "#t"))
      (obj-ref s 3))

    (method extension (self (param s VECTOR "A client session") (param keyword STRING "An extension, any case"))
      (doc "The parameters of an extension the server named, or nil where it named none of that name."
        (returns ANY "A LIST of STRINGs (empty for none), or nil")
        (example "(null? (Smtp extension (Smtp client (Wire script \"220 mx\\r\\n\")) \"SIZE\"))" "#t"))
      (let go ((l (obj-ref s 3)))
        (match ((null? l) ()) ((Str8 ci=? (first (first l)) keyword) (rest (first l))) (#t (go (rest l))))))

    (method tls? (self (param s VECTOR "A client session"))
      (doc "#t when the session is under TLS."
        (returns BOOL "#t under TLS")
        (example "(Smtp tls? (Smtp client (Wire script \"220 mx\\r\\n\")))" "#f"))
      (Wire tls? (obj-ref s 1)))

    (method starttls (self (param s VECTOR "A client session after hello")
                           . (param opts ALIST "(host . NAME), the name TLS checks; ('insecure) to skip that check"))
      (doc "STARTTLS: the session under TLS, then hello again with the same name, as RFC 3207 has it. A server that does not take it raises a label 'io. Answers the extensions named under TLS."
        (returns LIST "(KEYWORD . PARAMS) pairs")
        (sample "(Smtp starttls s (list 'insecure))" "the extensions named under TLS"))
      (%expect (%ask s "STARTTLS") 200 "STARTTLS")
      (Wire tls-connect (obj-ref s 1) (%tls-opts () opts))
      (self hello s (obj-ref s 2)))

    (method auth (self (param s VECTOR "A client session after hello")
                       (param user STRING "The user name")
                       (param password STRING "The password"))
      (doc "AUTH (RFC 4954): PLAIN where the server names it, else LOGIN. A server that names neither, or refuses the credentials, raises a label 'io."
        (returns ANY "#t")
        (example "(Smtp auth (Smtp client (Wire script \"220 mx\\r\\n235 ok\\r\\n\")) \"u\" \"p\")" "#t"))
      (def mechs (List map (fn (_ m) (Str8 upcase m)) (let ((m (self extension s "AUTH"))) (if (null? m) () m))))
      (if (if (List includes? "PLAIN" mechs) #t (null? mechs))
        (%expect (%ask s (Str8 append "AUTH PLAIN " (%plain user password))) 200 "AUTH PLAIN")
        (if (List includes? "LOGIN" mechs)
          (do (%expect (%ask s "AUTH LOGIN") 300 "AUTH LOGIN")
              (%expect (%ask s (Base64 encode user)) 300 "AUTH LOGIN user")
              (%expect (%ask s (Base64 encode password)) 200 "AUTH LOGIN password"))
          (%io "the server offers neither PLAIN nor LOGIN" mechs)))
      #t)

    (method send (self (param s VECTOR "A client session after hello")
                       (param from STRING "The sender's address, \"\" for none")
                       (param recipients LIST "Recipient addresses")
                       (param message ANY "A mail/message message, or its text"))
      (doc "Send one message: MAIL, RCPT for each recipient, then DATA with the text, its lines ended with CRLF and a dot put before any line that starts with one. Answers the recipients the server refused, each (ADDRESS . REPLY); where it took none, the transaction is reset and a label 'io raised."
        (returns LIST "(ADDRESS . REPLY) pairs, empty when every recipient was taken")
        (example "(Smtp send (Smtp client (Wire script \"220 mx\\r\\n250 ok\\r\\n250 ok\\r\\n550 no\\r\\n354 go\\r\\n250 ok\\r\\n\")) \"a@x\" (list \"b@y\" \"c@z\") \"Subject: hi\\n\\n.dot\\n\")" "((\"c@z\" 550 \"no\"))"))
      (%expect (%ask s (Str8 append "MAIL FROM:<" from ">")) 200 "MAIL")
      (def refused
        (List filter (fn (_ x) (not (null? x)))
          (List map (fn (_ to) (let ((r (%ask s (Str8 append "RCPT TO:<" to ">")))) (if (int= (%class r) 200) () (pair to r))))
                    recipients)))
      (when (int= (List length refused) (List length recipients))
        (do (%ask s "RSET") (%io "the server took no recipient" refused)))
      (%expect (%ask s "DATA") 300 "DATA")
      (Wire write (obj-ref s 1) (%data-text (if (str? message) message (Message write message))))
      (%expect (%reply (obj-ref s 1)) 200 "the message")
      refused)

    (method quit (self (param s VECTOR "A client session"))
      (doc "QUIT, then the wire closed."
        (returns ANY "nil")
        (example "(null? (Smtp quit (Smtp client (Wire script \"220 mx\\r\\n221 bye\\r\\n\"))))" "#t"))
      (guard (_ ()) (%ask s "QUIT"))
      (Wire close (obj-ref s 1))
      ())

    ; --- the server
    (method serve (self (param w VECTOR "A wire to a client")
                        (param opts ALIST "(name . HOST); (deliver . FN); (rcpt . FN); (auth . FN); (pem . TEXT); (size . N); ('auth-in-clear); ('require-auth)"))
      (doc "One server session on the wire: the greeting, then commands to QUIT or the wire's end. (name . HOST) names this server (localhost). (deliver . (fn (_ from recipients text info))) takes each message, its text with CRLF line ends and dots taken off, INFO an alist of hello, tls and user; a raise from it answers 451. (rcpt . (fn (_ address user))) says whether to take a recipient (all, without it). (auth . (fn (_ user password))) turns on AUTH PLAIN and LOGIN, offered under TLS only unless ('auth-in-clear). (pem . TEXT), a key and its certificates, turns on STARTTLS. (size . N) limits a message (10 MB). ('require-auth) refuses MAIL before AUTH. Answers the wire, not closed."
        (returns VECTOR "The wire")
        (example "(Wire output (Smtp serve (Wire script \"HELO me\\r\\nQUIT\\r\\n\") (list (pair 'name \"mx\"))))" "\"220 mx ESMTP\\r\\n250 mx\\r\\n221 2.0.0 Bye\\r\\n\""))
      (def st (%state w opts))
      (%say st 220 (Str8 append (let ((n (%opt (lit name) opts))) (if (null? n) "localhost" n)) " ESMTP"))
      (let go ()
        (unless (obj-ref st 7)
          (let ((line (guard (_ ()) (Wire read-line w))))
            (unless (null? line)
              (do (%serve-line st line) (go))))))
      w)))

(def %tls-opts
  (fn (_ host opts)
    (def name (%opt (lit host) opts))
    (List append
      (if (null? name) (if (null? host) () (list (pair (lit host) host))) (list (pair (lit host) name)))
      (if (%flag? (lit insecure) opts) (list (list (lit insecure))) ()))))

(doc (provide mail/smtp Smtp)
  "SMTP (RFC 5321) client and server, with STARTTLS (RFC 3207) and AUTH PLAIN and LOGIN (RFC 4954), over a socket, TLS, or a script for tests."
  (example "(Wire output (Smtp serve (Wire script \"QUIT\\r\\n\") ()))" "\"220 localhost ESMTP\\r\\n221 2.0.0 Bye\\r\\n\""))
