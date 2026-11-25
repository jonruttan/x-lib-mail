; wire.x -- Wire: a connection read and written a line at a time, for the
; mail protocols.
;
; A wire is a socket, a TLS session over a socket, or a script: text to read
; and a record of what was written, which runs either side of a protocol with
; no network.  A socket's wire turns into a TLS one in place, for STARTTLS or
; for TLS from the start; whatever was read ahead before the handshake is
; dropped, so nothing sent in the clear is taken as sent under TLS.
;
; A wire is a vector: 1 read, (fn (_ n)) a run (STRING . COUNT) or nil at the
; end; 2 write, (fn (_ s)); 3 close; 4 the bytes read ahead, a region; 5 the
; socket, or nil for a script; 6 #t once under TLS; 7 a script's writes,
; newest first.
(module mail/wire)

(import x/core/doors int+ int- int< int= obj-ref obj-set! str-byte-len str-byte-sub)
(import x/type/vector)
(import x/type/assoc)
(import x/sys/socket)
(import x/codec/bytes)

(def %io (fn (_ what data) (Err raise (lit io) (Str8 append "Wire: " what) data)))

(def %empty (list "" 0 0))

(def %make
  (fn (_ read write close fd)
    (def w (Vector make 7 0))
    (obj-set! w 1 read)
    (obj-set! w 2 write)
    (obj-set! w 3 close)
    (obj-set! w 4 %empty)
    (obj-set! w 5 fd)
    (obj-set! w 6 #f)
    (obj-set! w 7 ())
    w))

(def %max-line 65536)

(def %text (fn (_ r) (str-byte-sub (first r) (first (rest r)) (Bytes length r))))

; More bytes read onto what is read ahead; #f at the wire's end.
(def %fill!
  (fn (_ w)
    (def run ((obj-ref w 1) 4096))
    (if (if (null? run) #t (int= (rest run) 0))
      #f
      (do (obj-set! w 4 (Bytes join (obj-ref w 4) (list (first run) 0 (rest run)))) #t))))

; The wire under TLS: the session START makes from its socket.
(def %upgrade!
  (fn (_ w start)
    (def fd (obj-ref w 5))
    (when (null? fd) (%io "TLS needs a socket" ()))
    (import x/net/tls13)
    (def s (start fd))
    (obj-set! w 1 (fn (_ n) (Tls13 recv-run s n)))
    (obj-set! w 2 (fn (_ str) (Tls13 send s str)))
    (obj-set! w 3 (fn (_) (do (Tls13 close s) (Socket close fd))))
    (obj-set! w 4 %empty)
    (obj-set! w 6 #t)
    w))

(def %opt (fn (_ key opts) (let ((p (Assoc find key opts))) (if (null? p) () (rest p)))))

(def %flag? (fn (_ key opts) (List any? (fn (_ o) (if (pair? o) (eq? (first o) key) #f)) opts)))

(def-class Wire ()
  (doc "A connection read and written a line at a time: a socket, TLS on a socket, or a script that runs either side of a protocol with no network."
    (example "(Wire read-line (Wire script \"one\\r\\ntwo\\n\"))" "\"one\"")
    (see socket script read-line write-line tls-connect tls-accept))
  (static
    (method socket (self (param fd INTEGER "A connected socket"))
      (doc "A wire over a connected socket; close closes the socket."
        (returns VECTOR "A wire")
        (sample "(Wire socket (Socket tcp-connect \"127.0.0.1\" 25))" "a wire"))
      (%make (fn (_ n) (Socket recv-run fd n)) (fn (_ s) (Socket send fd s)) (fn (_) (Socket close fd)) fd))

    (method script (self (param text STRING "What the other side sends, all of it"))
      (doc "A wire that reads text and then its end, and keeps what is written to it for output."
        (returns VECTOR "A wire")
        (example "(Wire output (Wire script \"\"))" "\"\""))
      (def w (%make () () (fn (_) ()) ()))
      (def left (Vector make 1 0))
      (obj-set! left 1 text)
      (obj-set! w 1 (fn (_ n) (if (null? (obj-ref left 1)) ()
                                (let ((t (obj-ref left 1))) (do (obj-set! left 1 ()) (pair t (str-byte-len t)))))))
      (obj-set! w 2 (fn (_ s) (obj-set! w 7 (pair s (obj-ref w 7)))))
      w)

    (method output (self (param w VECTOR "A script wire"))
      (doc "Everything written to a script wire so far, in order."
        (returns STRING "The text written")
        (example "((fn (_ w) (Wire write-line w \"hi\") (Wire output w)) (Wire script \"\"))" "\"hi\\r\\n\""))
      (Str8 join "" (List reverse (obj-ref w 7))))

    (method read-line (self (param w VECTOR "A wire"))
      (doc "The next line without its line end, or nil at the wire's end. A line ends at LF, a CR before it dropped; the text after the last LF is a line of its own. A line past 64 KB raises a label 'io."
        (returns ANY "A STRING, or nil")
        (example "((fn (_ w) (list (Wire read-line w) (Wire read-line w) (Wire read-line w))) (Wire script \"a\\r\\nb\"))" "(\"a\" \"b\" ())"))
      (let go ()
        (def buf (obj-ref w 4))
        (def at (Bytes find buf "\n"))
        (if (null? at)
          (do (when (int< %max-line (Bytes length buf)) (%io "a line longer than the limit" (Bytes length buf)))
              (if (%fill! w)
                (go)
                (if (int= (Bytes length buf) 0) () (do (obj-set! w 4 %empty) (%text buf)))))
          (do (def end (if (int< 0 at) (if (int= (Bytes ref buf (int- at 1)) 13) (int- at 1) at) at))
              (obj-set! w 4 (Bytes sub buf (int+ at 1) (int- (Bytes length buf) (int+ at 1))))
              (str-byte-sub (first buf) (first (rest buf)) end)))))

    (method read-bytes (self (param w VECTOR "A wire") (param n INTEGER "How many bytes"))
      (doc "The next n bytes, line ends and all, as IMAP's literals carry them. The wire's end before n raises a label 'io."
        (returns STRING "n bytes")
        (example "((fn (_ w) (list (Wire read-bytes w 4) (Wire read-line w))) (Wire script \"ab\\r\\ncd\\r\\n\"))" "(\"ab\\r\\n\" \"cd\")"))
      (def out (Bytes writer))
      (let go ((need n))
        (def buf (obj-ref w 4))
        (def k (if (int< (Bytes length buf) need) (Bytes length buf) need))
        (Bytes put out (Bytes sub buf 0 k))
        (obj-set! w 4 (Bytes sub buf k (int- (Bytes length buf) k)))
        (match
          ((int= k need) ())
          ((%fill! w) (go (int- need k)))
          (#t (%io "the connection closed in a literal" n))))
      (%text (Bytes written out)))

    (method write (self (param w VECTOR "A wire") (param s STRING "The bytes"))
      (doc "Send s as it is."
        (returns ANY "What the wire answers")
        (example "((fn (_ w) (Wire write w \"x\") (Wire output w)) (Wire script \"\"))" "\"x\""))
      ((obj-ref w 2) s))

    (method write-line (self (param w VECTOR "A wire") (param s STRING "A line, without its line end"))
      (doc "Send s and CRLF."
        (returns ANY "What the wire answers")
        (example "((fn (_ w) (Wire write-line w \"x\") (Wire output w)) (Wire script \"\"))" "\"x\\r\\n\""))
      ((obj-ref w 2) (Str8 append s "\r\n")))

    (method close (self (param w VECTOR "A wire"))
      (doc "Close the wire: close_notify first under TLS, then the socket."
        (returns ANY "nil")
        (example "(null? (Wire close (Wire script \"\")))" "#t"))
      ((obj-ref w 3))
      ())

    (method tls? (self (param w VECTOR "A wire"))
      (doc "#t once the wire is under TLS."
        (returns BOOL "#t under TLS")
        (example "(Wire tls? (Wire script \"\"))" "#f"))
      (obj-ref w 6))

    (method tls-connect (self (param w VECTOR "A socket wire to a server")
                              (param opts ALIST "(host . NAME), the name TLS sends and checks; ('insecure) to skip the check"))
      (doc "The wire under TLS as the client, the server authenticated unless ('insecure): for STARTTLS, or for TLS from the start. Whatever was read ahead is dropped. A script wire, or a failed handshake, raises a label 'io."
        (returns VECTOR "The wire")
        (sample "(Wire tls-connect w (list (pair 'host \"mail.example.org\")))" "the wire under TLS"))
      (def name (%opt (lit host) opts))
      (%upgrade! w
        (fn (_ fd)
          (Tls13 over fd fd
            (List append (if (null? name) () (list (pair (lit host) name)))
                         (if (%flag? (lit insecure) opts) (list (list (lit insecure))) ()))))))

    (method tls-accept (self (param w VECTOR "A socket wire to a client")
                             (param pem STRING "PEM text: the private key, RSA or Ed25519, and the certificates, leaf first"))
      (doc "The wire under TLS as the server: for STARTTLS, or for TLS from the start. Whatever was read ahead is dropped. A script wire, or a failed handshake, raises a label 'io."
        (returns VECTOR "The wire")
        (sample "(Wire tls-accept (Wire socket fd) pem)" "the wire under TLS"))
      (%upgrade! w (fn (_ fd) (Tls13 accept fd fd (list (pair (lit pem) pem))))))))

(doc (provide mail/wire Wire)
  "A connection for the mail protocols, read and written a line at a time: a socket, TLS on a socket, or a script for tests."
  (example "(Wire read-line (Wire script \"220 hi\\r\\n\"))" "\"220 hi\""))
