; imap.x -- Imap: an IMAP client (RFC 9051, IMAP4rev2, and RFC 3501, IMAP4rev1).
;
; The client talks over a mail/wire wire: a socket, TLS on a socket (993, or
; STARTTLS on 143), or a script that plays the server with no network.  After
; LOGIN it takes IMAP4rev2 where the server offers it (ENABLE), and IMAP4rev1
; otherwise.
;
; The calls mirror mail/maildir's with a connection in the root's place:
; folders, messages, read, flag!, move!, create!, each folder a list of names.
; A message is an entry (KEY NEW? FLAGS INFO): KEY is "UIDVALIDITY.UID", NEW?
; is \Recent (IMAP4rev1 only; IMAP4rev2 has none, so #f), FLAGS the symbols
; draft flagged passed replied seen trashed, INFO what messages fetched.  A
; message is unread when its FLAGS lack seen; NEW? says nothing of that.
; Keywords other than $Forwarded stay out of the entry, and flag! changes only
; the six flags, so the server's other keywords stay as they are.
;
; UIDs and UIDVALIDITY are 32-bit unsigned, past a 32-bit engine's integers,
; so they stay the digit strings the server sent.
;
; A response is read whole, literals and all, and parsed into values: an atom
; or a string is a STRING, NIL is nil, a parenthesised list a LIST, and a
; bracketed one (sect . ITEMS).  A tagged NO or BAD, or a closed connection,
; raises a label 'io with the response as its data; a malformed call raises a
; label 'value.
(module mail/imap)

(import x/core/doors char->int int+ int- int< int= obj-ref obj-set! str-byte-len str-byte-ref str-byte-sub)
(import x/type/vector)
(import x/type/assoc)
(import x/sys/socket)
(import x/codec/bytes)
(import mail/wire)
(import mail/utf7)

(def %io (fn (_ what data) (Err raise (lit io) (Str8 append "Imap: " what) data)))

(def %fail (fn (_ what data) (Err raise (lit value) (Str8 append "Imap: " what) data)))

(def %byte (fn (_ s i) (char->int (str-byte-ref s i))))

(def %opt (fn (_ key opts) (let ((p (Assoc find key opts))) (if (null? p) () (rest p)))))

(def %flag? (fn (_ key opts) (List any? (fn (_ o) (if (pair? o) (eq? (first o) key) #f)) opts)))

(def %is? (fn (_ x name) (if (str? x) (Str8 ci=? x name) #f)))

(def %number (fn (_ s) (if (str? s) (guard (_ ()) (%str->number s)) ())))

(def %text (fn (_ r) (str-byte-sub (first r) (first (rest r)) (Bytes length r))))

(def %nth (fn (_ l i) (if (null? l) () (if (int= i 0) (first l) (%nth (rest l) (int- i 1))))))

; s cut at each byte c.
(def %split
  (fn (_ s c)
    (def n (str-byte-len s))
    (let go ((i 0) (start 0) (acc ()))
      (match
        ((int= i n) (List reverse (pair (str-byte-sub s start (int- i start)) acc)))
        ((int= (%byte s i) c) (go (int+ i 1) (int+ i 1) (pair (str-byte-sub s start (int- i start)) acc)))
        (#t (go (int+ i 1) start acc))))))

; UIDs in numeric order, as digit strings with no leading zeros.
(def %uid<?
  (fn (_ a b)
    (if (int= (str-byte-len a) (str-byte-len b)) (Str8 <? a b) (int< (str-byte-len a) (str-byte-len b)))))

; --- reading responses

; The size of the literal "{N}" or "{N+}" that ends a line, and where it
; starts: (N . AT), or nil.
(def %literal-at
  (fn (_ line)
    (def n (str-byte-len line))
    (if (if (int< 2 n) (int= (%byte line (int- n 1)) 125) #f)
      (let go ((i (int- n 2)))
        (match
          ((int< i 0) ())
          ((int= (%byte line i) 123)
            (let ((digits (str-byte-sub line (int+ i 1) (int- n (int+ i 2)))))
              (def d (if (Str8 ends? "+" digits) (str-byte-sub digits 0 (int- (str-byte-len digits) 1)) digits))
              (def size (if (int< 0 (str-byte-len d)) (%number d) ()))
              (if (null? size) () (pair size i))))
          ((if (int< 47 (%byte line i)) (int< (%byte line i) 58) #f) (go (int- i 1)))
          ((int= (%byte line i) 43) (go (int- i 1)))
          (#t ())))
      ())))

; One response as it came: its lines, and the literals they announce, as
; (text . LINE) and (literal . BYTES) in order.
(def %response
  (fn (_ w)
    (let go ((acc ()))
      (def line (Wire read-line w))
      (when (null? line) (%io "the connection closed" ()))
      (def at (%literal-at line))
      (if (null? at)
        (List reverse (pair (pair (lit text) line) acc))
        (go (pair (pair (lit literal) (Wire read-bytes w (first at)))
                  (pair (pair (lit text) (str-byte-sub line 0 (rest at))) acc)))))))

(def %atom-end? (fn (_ c) (match ((int= c 32) #t) ((int= c 40) #t) ((int= c 41) #t) ((int= c 91) #t) ((int= c 93) #t) ((int= c 34) #t) (#t #f))))

; A quoted string from just past its opening quote: (STRING . NEXT).
(def %quoted
  (fn (_ s i n)
    (let go ((j i) (out ()))
      (match
        ((int= j n) (pair (bytes->str (List reverse out)) j))
        ((int= (%byte s j) 34) (pair (bytes->str (List reverse out)) (int+ j 1)))
        ((if (int= (%byte s j) 92) (int< (int+ j 1) n) #f) (go (int+ j 2) (pair (%byte s (int+ j 1)) out)))
        (#t (go (int+ j 1) (pair (%byte s j) out)))))))

; A line's tokens onto out, newest first: the symbols open close bopen bclose,
; an atom as a STRING, a quoted string as (str . STRING).
(def %scan
  (fn (_ s out)
    (def n (str-byte-len s))
    (let go ((i 0) (out out))
      (match
        ((int= i n) out)
        ((int= (%byte s i) 32) (go (int+ i 1) out))
        ((int= (%byte s i) 40) (go (int+ i 1) (pair (lit open) out)))
        ((int= (%byte s i) 41) (go (int+ i 1) (pair (lit close) out)))
        ((int= (%byte s i) 91) (go (int+ i 1) (pair (lit bopen) out)))
        ((int= (%byte s i) 93) (go (int+ i 1) (pair (lit bclose) out)))
        ((int= (%byte s i) 34)
          (let ((q (%quoted s (int+ i 1) n))) (go (rest q) (pair (pair (lit str) (first q)) out))))
        (#t
          (let ((j (let to ((j (int+ i 1))) (if (if (int< j n) (not (%atom-end? (%byte s j))) #f) (to (int+ j 1)) j))))
            (go j (pair (str-byte-sub s i (int- j i)) out))))))))

(def %tokens
  (fn (_ chunks)
    (let go ((l chunks) (out ()))
      (match
        ((null? l) (List reverse out))
        ((eq? (first (first l)) (lit literal)) (go (rest l) (pair (pair (lit str) (rest (first l))) out)))
        (#t (go (rest l) (%scan (rest (first l)) out)))))))

; Tokens to values up to the stop token: (VALUES . REST).  A close with no
; open is passed over, and an open with no close ends at the response's end.
(def %parse
  (fn (self toks stop)
    (let go ((l toks) (out ()))
      (match
        ((null? l) (pair (List reverse out) ()))
        ((eq? (first l) stop) (pair (List reverse out) (rest l)))
        ((eq? (first l) (lit open)) (let ((r (self (rest l) (lit close)))) (go (rest r) (pair (first r) out))))
        ((eq? (first l) (lit bopen)) (let ((r (self (rest l) (lit bclose)))) (go (rest r) (pair (pair (lit sect) (first r)) out))))
        ((symbol? (first l)) (go (rest l) out))
        ((pair? (first l)) (go (rest l) (pair (rest (first l)) out)))
        ((Str8 ci=? (first l) "NIL") (go (rest l) (pair () out)))
        (#t (go (rest l) (pair (first l) out)))))))

(def %values (fn (_ w) (first (%parse (%tokens (%response w)) (lit none)))))

(def %sect? (fn (_ x) (if (pair? x) (eq? (first x) (lit sect)) #f)))

; A status response's code (NAME . ARGS) when it is name, else nil:
; ("OK" (sect "UIDVALIDITY" "3857529045") ...) has UIDVALIDITY.
(def %code
  (fn (_ v name)
    (def c (if (pair? v) (if (pair? (rest v)) (first (rest v)) ()) ()))
    (if (if (%sect? c) (if (pair? (rest c)) (%is? (first (rest c)) name) #f) #f) (rest c) ())))

; --- the connection
;
; A connection is a vector: 1 the wire, 2 the last tag's number, 3 the
; capabilities, upper case, 4 #t under IMAP4rev2, 5 the selected mailbox's
; name on the wire, or nil, 6 its UIDVALIDITY, 7 the hierarchy delimiter, nil
; for none, unknown until asked, 8 its message count.

(def %conn
  (fn (_ w)
    (def c (Vector make 8 0))
    (obj-set! c 1 w)
    (obj-set! c 2 0)
    (obj-set! c 3 ())
    (obj-set! c 4 #f)
    (obj-set! c 5 ())
    (obj-set! c 6 ())
    (obj-set! c 7 (lit unknown))
    (obj-set! c 8 0)
    c))

(def %has? (fn (_ c cap) (List any? (fn (_ k) (str=? k cap)) (obj-ref c 3))))

(def %caps! (fn (_ c items) (obj-set! c 3 (List map (fn (_ k) (Str8 upcase k)) (List filter str? items)))))

; What an untagged response, or a status's code, tells the connection.
(def %observe!
  (fn (_ c u)
    (def cap (%code u "CAPABILITY"))
    (match
      ((%is? (first u) "CAPABILITY") (%caps! c (rest u)))
      ((not (null? cap)) (%caps! c (rest cap)))
      ((%is? (%nth u 1) "EXISTS") (obj-set! c 8 (%number (first u))))
      ((%is? (%nth u 1) "EXPUNGE") (obj-set! c 8 (int- (obj-ref c 8) 1)))
      (#t ()))))

(def %tag!
  (fn (_ c)
    (obj-set! c 2 (int+ (obj-ref c 2) 1))
    (Str8 append "a" (Str8 str (obj-ref c 2)))))

; Responses up to the one tagged tag, or a continuation when more? is #t:
; (UNTAGGED . STATUS), the untagged ones newest first, STATUS the tagged
; response after its tag, or nil for a continuation.
(def %until
  (fn (_ c tag seen more?)
    (let go ((seen seen))
      (def v (%values (obj-ref c 1)))
      (match
        ((null? v) (go seen))
        ((%is? (first v) "*") (do (%observe! c (rest v)) (go (pair (rest v) seen))))
        ((%is? (first v) "+") (if more? (pair seen ()) (%io "a continuation no command asked for" v)))
        ((%is? (first v) tag) (do (%observe! c (rest v)) (pair seen (rest v))))
        (#t (go seen))))))

; Send a command, its parts a STRING each or (literal . BYTES), waiting for
; the server's continuation before each literal.  Answers (UNTAGGED . STATUS)
; with the untagged responses in order.
(def %run-raw
  (fn (_ c parts)
    (def w (obj-ref c 1))
    (def tag (%tag! c))
    (def r
      (let go ((l parts) (line tag) (seen ()))
        (match
          ((null? l) (do (Wire write-line w line) (%until c tag seen #f)))
          ((pair? (first l))
            (do (Wire write-line w (Str8 str line " {" (str-byte-len (rest (first l))) "}"))
                (let ((k (%until c tag seen #t)))
                  (if (null? (rest k))
                    (do (Wire write w (rest (first l))) (go (rest l) "" (first k)))
                    k))))
          (#t (go (rest l) (Str8 str line " " (first l)) seen)))))
    (pair (List reverse (first r)) (rest r))))

(def %ok? (fn (_ r) (%is? (first (rest r)) "OK")))

(def %run
  (fn (_ c parts)
    (def r (%run-raw c parts))
    (unless (%ok? r)
      (%io (Str8 join " " (pair (first parts) (List filter str? (rest r)))) (rest r)))
    r))

; s as an IMAP string: quoted where it can be, else a literal.
(def %astring
  (fn (_ s)
    (def n (str-byte-len s))
    (if (let ok ((i 0)) (match ((int= i n) #t) ((int< 126 (%byte s i)) #f) ((int< (%byte s i) 32) #f) (#t (ok (int+ i 1)))))
      (Str8 str "\"" (Str8 replace "\"" "\\\"" (Str8 replace "\\" "\\\\" s)) "\"")
      (pair (lit literal) s))))

; The untagged responses whose second value is name: "* 3 FETCH (...)".
(def %named
  (fn (_ r name) (List filter (fn (_ u) (%is? (%nth u 1) name)) (first r))))

; The untagged responses whose first value is name: "* LIST (...)".
(def %leading
  (fn (_ r name) (List filter (fn (_ u) (%is? (first u) name)) (first r))))

; --- folders

(def %delimiter
  (fn (_ c)
    (when (eq? (obj-ref c 7) (lit unknown))
      (def lists (%leading (%run c (list "LIST" "\"\"" "\"\"")) "LIST"))
      (obj-set! c 7 (if (null? lists) () (%nth (first lists) 2))))
    (obj-ref c 7)))

; A folder's mailbox name on the wire: INBOX in any case is INBOX, every other
; name modified UTF-7, the names joined by the server's delimiter.
(def %mailbox
  (fn (_ c folder)
    (unless (if (pair? folder) (List all? (fn (_ s) (if (str? s) (int< 0 (str-byte-len s)) #f)) folder) #f)
      (%fail "a folder is a list of names, none empty" folder))
    (if (if (null? (rest folder)) (Str8 ci=? (first folder) "INBOX") #f)
      "INBOX"
      (do (def d (%delimiter c))
          (def parts (List map (fn (_ p) (Utf7 encode p)) folder))
          (when (if (null? d) (not (null? (rest folder))) #f)
            (%fail "the server has no hierarchy: a folder is one name" folder))
          (unless (null? d)
            (when (List any? (fn (_ p) (not (null? (Str8 index-of d p)))) parts)
              (%fail (Str8 append "a name with the server's delimiter in it: " d) folder)))
          (if (null? d) (first parts) (Str8 join d parts))))))

(def %folder-of
  (fn (_ name d)
    (if (Str8 ci=? name "INBOX")
      (list "INBOX")
      (List map (fn (_ p) (Utf7 decode p)) (if (null? d) (list name) (%split name (%byte d 0)))))))

(def %select!
  (fn (_ c box)
    (obj-set! c 5 ())
    (def r (%run c (list "SELECT" (%astring box))))
    (def status (List append (first r) (list (rest r))))
    (def code-arg
      (fn (_ name)
        (let go ((l status))
          (match
            ((null? l) ())
            ((not (null? (%code (first l) name))) (%nth (%code (first l) name) 1))
            (#t (go (rest l)))))))
    (def count
      (fn (_ name) (let ((u (%named r name))) (if (null? u) 0 (%number (first (first u)))))))
    (obj-set! c 5 box)
    (obj-set! c 6 (code-arg "UIDVALIDITY"))
    (obj-set! c 8 (count "EXISTS"))
    (list (pair (lit exists) (obj-ref c 8))
          (pair (lit recent) (count "RECENT"))
          (pair (lit uidvalidity) (obj-ref c 6))
          (pair (lit uidnext) (code-arg "UIDNEXT"))
          (pair (lit read-only) (not (null? (%code (rest r) "READ-ONLY")))))))

(def %ensure!
  (fn (_ c folder)
    (def box (%mailbox c folder))
    (unless (if (null? (obj-ref c 5)) #f (str=? box (obj-ref c 5))) (%select! c box))
    box))

; --- entries

; In the order Maildir flags gives them.
(def %flag-names
  (lit ((draft . "\\Draft") (flagged . "\\Flagged") (passed . "$Forwarded")
        (replied . "\\Answered") (seen . "\\Seen") (trashed . "\\Deleted"))))

(def %flags-of
  (fn (_ names)
    (List map first
      (List filter (fn (_ f) (List any? (fn (_ n) (%is? n (rest f))) names)) %flag-names))))

(def %ordered
  (fn (_ flags)
    (List for-each
      (fn (_ s) (unless (Assoc find s %flag-names) (%fail "not a flag: draft flagged passed replied seen trashed" s)))
      flags)
    (List map first (List filter (fn (_ f) (List any? (fn (_ s) (eq? s (first f))) flags)) %flag-names))))

; A FETCH response's items as (NAME . VALUE), NAME in upper case; BODY[...]'s
; section is passed over.
(def %items
  (fn (_ l)
    (let go ((l l) (acc ()))
      (match
        ((if (null? l) #t (null? (rest l))) acc)
        ((not (str? (first l))) (go (rest l) acc))
        ((%sect? (first (rest l)))
          (if (null? (rest (rest l)))
            acc
            (go (rest (rest (rest l))) (pair (pair (Str8 upcase (first l)) (first (rest (rest l)))) acc))))
        (#t (go (rest (rest l)) (pair (pair (Str8 upcase (first l)) (first (rest l))) acc)))))))

(def %item
  (fn (_ items name)
    (let go ((l items)) (match ((null? l) ()) ((str=? (first (first l)) name) (rest (first l))) (#t (go (rest l)))))))

; An ENVELOPE address list as a header would carry it, or nil: "Name
; <box@host>, box@host"; a group's start and end are left out.
(def %addresses
  (fn (_ l)
    (def one
      (fn (_ a)
        (def box (%nth a 2))
        (def host (%nth a 3))
        (if (if (str? box) (str? host) #f)
          (let ((at (Str8 str box "@" host)))
            (if (str? (first a)) (Str8 str (first a) " <" at ">") at))
          ())))
    (def all (List filter str? (List map one (if (pair? l) l ()))))
    (if (null? all) () (Str8 join ", " all))))

(def %info
  (fn (_ items)
    (def env (%item items "ENVELOPE"))
    (list (pair (lit date) (%nth env 0))
          (pair (lit from) (%addresses (%nth env 2)))
          (pair (lit to) (%addresses (%nth env 5)))
          (pair (lit cc) (%addresses (%nth env 6)))
          (pair (lit subject) (%nth env 1))
          (pair (lit message-id) (%nth env 9))
          (pair (lit in-reply-to) (%nth env 8))
          (pair (lit internal-date) (%item items "INTERNALDATE"))
          (pair (lit size) (%number (%item items "RFC822.SIZE"))))))

(def %entry
  (fn (_ c items)
    (def names (let ((f (%item items "FLAGS"))) (if (pair? f) f ())))
    (list (Str8 str (obj-ref c 6) "." (%item items "UID"))
          (if (obj-ref c 4) #f (List any? (fn (_ n) (%is? n "\\Recent")) names))
          (%flags-of names)
          (%info items))))

; The entry's UID, once its UIDVALIDITY is the selected mailbox's.
(def %uid
  (fn (_ c entry)
    (def key (if (pair? entry) (first entry) ()))
    (def dot (if (str? key) (Str8 index-of "." key) ()))
    (when (null? dot) (%fail "an entry's KEY is UIDVALIDITY.UID" entry))
    (unless (str=? (str-byte-sub key 0 dot) (if (null? (obj-ref c 6)) "" (obj-ref c 6)))
      (%fail "the entry is from another UIDVALIDITY of the folder" key))
    (str-byte-sub key (int+ dot 1) (int- (str-byte-len key) (int+ dot 1)))))

(def %key-uid
  (fn (_ key)
    (def dot (Str8 index-of "." key))
    (str-byte-sub key (int+ dot 1) (int- (str-byte-len key) (int+ dot 1)))))

(def %sort-entries (fn (_ l) (List sort (fn (_ a b) (%uid<? (%key-uid (first a)) (%key-uid (first b)))) l)))

; A sequence set's numbers as digit strings: "1:3,7" is 1 2 3 7.
(def %expand
  (fn (_ set)
    (List fold
      (fn (_ acc part)
        (def colon (Str8 index-of ":" part))
        (if (null? colon)
          (List append acc (list part))
          (let ((a (%number (str-byte-sub part 0 colon)))
                (b (%number (str-byte-sub part (int+ colon 1) (int- (str-byte-len part) (int+ colon 1))))))
            (def lo (if (< b a) b a))
            (def hi (if (< b a) a b))
            (List append acc (let go ((n hi) (out ())) (if (< n lo) out (go (- n 1) (pair (Str8 str n) out))))))))
      () (%split set 44))))

; The COPYUID code's new key, from the tagged status or an untagged OK.
(def %copied-key
  (fn (_ r)
    (def code
      (let go ((l (pair (rest r) (first r))))
        (match ((null? l) ()) ((not (null? (%code (first l) "COPYUID"))) (%code (first l) "COPYUID")) (#t (go (rest l))))))
    (if (null? code) () (Str8 str (%nth code 1) "." (%nth code 3)))))

; text with every line ended with CRLF, as APPEND wants it.
(def %crlf
  (fn (_ text)
    (def out (Bytes writer))
    (let go ((r (list text 0 (str-byte-len text))))
      (def at (Bytes find r "\n"))
      (if (null? at)
        (Bytes put out r)
        (do (def end (if (int< 0 at) (if (int= (Bytes ref r (int- at 1)) 13) (int- at 1) at) at))
            (Bytes put out (Bytes sub r 0 end))
            (Bytes put out (list "\r\n" 0 2))
            (go (Bytes sub r (int+ at 1) (int- (Bytes length r) (int+ at 1)))))))
    (%text (Bytes written out))))

(def %enable!
  (fn (_ c)
    (match
      ((not (%has? c "IMAP4REV2")) ())
      ((not (%has? c "IMAP4REV1")) (obj-set! c 4 #t))
      ((%has? c "ENABLE")
        (let ((r (%run c (list "ENABLE" "IMAP4rev2"))))
          (obj-set! c 4 (List any? (fn (_ u) (List any? (fn (_ k) (%is? k "IMAP4rev2")) (rest u))) (%leading r "ENABLED")))))
      (#t ()))))

(def %tls-opts
  (fn (_ host opts)
    (def name (%opt (lit host) opts))
    (List append
      (if (null? name) (if (null? host) () (list (pair (lit host) host))) (list (pair (lit host) name)))
      (if (%flag? (lit insecure) opts) (list (list (lit insecure))) ()))))

(def-class Imap ()
  (doc "An IMAP client (RFC 9051 IMAP4rev2, RFC 3501 IMAP4rev1) with the calls of mail/maildir: folders, messages, read, flag!, move!, create!, a connection in the root's place. A message is an entry (KEY NEW? FLAGS INFO), KEY \"UIDVALIDITY.UID\"."
    (example "(Imap capabilities (Imap client (Wire script \"* OK [CAPABILITY IMAP4rev1 MOVE] hi\\r\\n\")))" "(\"IMAP4REV1\" \"MOVE\")")
    (see connect client login folders messages read flag! move! create! search append logout))
  (static
    (method client (self (param w VECTOR "A wire to a server"))
      (doc "A connection on the wire, once the server's greeting is read and its capabilities known: from the greeting, or asked for. A PREAUTH greeting is logged in already. A BYE, or any other greeting, raises a label 'io."
        (returns VECTOR "A connection")
        (example "(Imap capabilities (Imap client (Wire script \"* OK hi\\r\\n* CAPABILITY IMAP4rev1\\r\\na1 OK done\\r\\n\")))" "(\"IMAP4REV1\")"))
      (def c (%conn w))
      (def v (%values w))
      (unless (if (%is? (first v) "*") (if (%is? (%nth v 1) "OK") #t (%is? (%nth v 1) "PREAUTH")) #f)
        (%io "the greeting is not OK" v))
      (%observe! c (rest v))
      (when (null? (obj-ref c 3)) (%run c (list "CAPABILITY")))
      (when (%is? (%nth v 1) "PREAUTH") (%enable! c))
      c)

    (method connect (self (param host STRING "A host name or dotted quad")
                          (param port INTEGER "Usually 143, or 993 for TLS from the start")
                          . (param opts ALIST "('tls) for TLS from the start; (host . NAME), the name TLS checks; ('insecure) to skip that check"))
      (doc "A connection to host:port, under TLS from the start with ('tls), once the greeting is read. A failure raises a label 'io."
        (returns VECTOR "A connection")
        (sample "(Imap connect \"imap.example.org\" 993 (list 'tls))" "a connection"))
      (def w (Wire socket (Socket tcp-connect (Socket resolve host) port)))
      (when (%flag? (lit tls) opts) (Wire tls-connect w (%tls-opts host opts)))
      (self client w))

    (method wire (self (param c VECTOR "A connection"))
      (doc "The connection's wire: for Wire output on a script, or Wire tls?."
        (returns VECTOR "A wire")
        (example "(Wire output (Imap wire (Imap client (Wire script \"* OK [CAPABILITY IMAP4rev1] hi\\r\\n\"))))" "\"\""))
      (obj-ref c 1))

    (method capabilities (self (param c VECTOR "A connection"))
      (doc "The capabilities the server named last, in upper case."
        (returns LIST "STRINGs")
        (example "(Imap capabilities (Imap client (Wire script \"* OK [CAPABILITY IMAP4rev1 IDLE] hi\\r\\n\")))" "(\"IMAP4REV1\" \"IDLE\")"))
      (obj-ref c 3))

    (method rev2? (self (param c VECTOR "A connection"))
      (doc "#t once the connection speaks IMAP4rev2: after login to a server that offers it."
        (returns BOOL "#t under IMAP4rev2")
        (example "(Imap rev2? (Imap client (Wire script \"* OK [CAPABILITY IMAP4rev1 IMAP4rev2] hi\\r\\n\")))" "#f"))
      (obj-ref c 4))

    (method starttls (self (param c VECTOR "A connection, not logged in")
                           . (param opts ALIST "(host . NAME), the name TLS checks; ('insecure) to skip that check"))
      (doc "STARTTLS: the connection under TLS, and the capabilities asked for again, since those named in the clear do not count (RFC 9051 6.2.1). A server that refuses raises a label 'io. Answers the capabilities."
        (returns LIST "STRINGs")
        (sample "(Imap starttls c (list (pair 'host \"imap.example.org\")))" "the capabilities under TLS"))
      (%run c (list "STARTTLS"))
      (Wire tls-connect (obj-ref c 1) (%tls-opts () opts))
      (obj-set! c 3 ())
      (%run c (list "CAPABILITY"))
      (obj-ref c 3))

    (method login (self (param c VECTOR "A connection")
                        (param user STRING "The user name")
                        (param password STRING "The password"))
      (doc "LOGIN, then IMAP4rev2 where the server offers it. A server that names LOGINDISABLED (before STARTTLS, say), or refuses the credentials, raises a label 'io."
        (returns ANY "#t")
        (example "(Imap login (Imap client (Wire script \"* OK [CAPABILITY IMAP4rev1] hi\\r\\na1 OK [CAPABILITY IMAP4rev1 MOVE] in\\r\\n\")) \"u\" \"p\")" "#t"))
      (when (%has? c "LOGINDISABLED") (%io "the server takes no LOGIN here: LOGINDISABLED" (obj-ref c 3)))
      (obj-set! c 3 ())
      (%run c (list "LOGIN" (%astring user) (%astring password)))
      (when (null? (obj-ref c 3)) (%run c (list "CAPABILITY")))
      (%enable! c)
      #t)

    (method folders (self (param c VECTOR "A logged-in connection"))
      (doc "Every folder that can be selected: (\"INBOX\") first, then the others in the order of their names on the wire. Names come out of modified UTF-7."
        (returns LIST "Folders, each a list of names")
        (sample "(Imap folders c)" "((\"INBOX\") (\"Archive\" \"2026\") (\"Entwürfe\") (\"Sent\"))"))
      (def lists (%leading (%run c (list "LIST" "\"\"" "\"*\"")) "LIST"))
      (when (if (eq? (obj-ref c 7) (lit unknown)) (pair? lists) #f) (obj-set! c 7 (%nth (first lists) 2)))
      (def usable
        (List filter
          (fn (_ u)
            (def attrs (%nth u 1))
            (if (str? (%nth u 3))
              (not (List any? (fn (_ a) (if (%is? a "\\Noselect") #t (%is? a "\\NonExistent"))) (if (pair? attrs) attrs ())))
              #f))
          lists))
      (def inbox (List filter (fn (_ u) (Str8 ci=? (%nth u 3) "INBOX")) usable))
      (def others (List sort (fn (_ a b) (Str8 <? (%nth a 3) (%nth b 3))) (List filter (fn (_ u) (not (Str8 ci=? (%nth u 3) "INBOX"))) usable)))
      (List map (fn (_ u) (%folder-of (%nth u 3) (%nth u 2))) (List append (if (null? inbox) () (list (first inbox))) others)))

    (method select (self (param c VECTOR "A logged-in connection") (param folder LIST "A folder"))
      (doc "SELECT the folder, as the other calls do on their own when it is not selected. Answers what the server said of it: (exists . N) (recent . N), 0 under IMAP4rev2, (uidvalidity . DIGITS) (uidnext . DIGITS) (read-only . BOOL)."
        (returns ALIST "The folder's state")
        (example "(Imap select (Imap client (Wire script \"* PREAUTH [CAPABILITY IMAP4rev1] hi\\r\\n* 2 EXISTS\\r\\n* OK [UIDVALIDITY 7] v\\r\\na1 OK [READ-WRITE] done\\r\\n\")) (list \"INBOX\"))" "(('exists . 2) ('recent . 0) ('uidvalidity . \"7\") ('uidnext) ('read-only . #f))"))
      (%select! c (%mailbox c folder)))

    (method messages (self (param c VECTOR "A logged-in connection") (param folder LIST "A folder"))
      (doc "The folder's messages as entries (KEY NEW? FLAGS INFO) in UID order. INFO is (date . TEXT) (from . TEXT) (to . TEXT) (cc . TEXT) (subject . TEXT) (message-id . TEXT) (in-reply-to . TEXT) (internal-date . TEXT) (size . N), from the ENVELOPE as the header carries it (Message decode-words reads an encoded subject or name), each nil where the message has none."
        (returns LIST "Entries")
        (sample "(Imap messages c (list \"INBOX\"))" "((\"1700000000.41\" #f (seen) ((date . \"Mon, 23 Nov 2026 10:00:00 +0000\") (from . \"Ann <ann@example.org>\") ...)))"))
      (%ensure! c folder)
      (if (int= (obj-ref c 8) 0)
        ()
        (%sort-entries
          (List map (fn (_ u) (%entry c (%items (%nth u 2))))
            (List filter
              (fn (_ u) (let ((items (%items (%nth u 2)))) (if (null? (%item items "UID")) #f (not (null? (%item items "ENVELOPE"))))))
              (%named (%run c (list "UID FETCH 1:* (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)")) "FETCH"))))))

    (method read (self (param c VECTOR "A logged-in connection") (param folder LIST "A folder") (param entry LIST "An entry"))
      (doc "The message's whole text, as Message parse takes it, fetched with BODY.PEEK[] so the seen flag stays as it was. An entry the server has no message for raises a label 'value."
        (returns STRING "The message")
        (sample "(Message parse (Imap read c (list \"INBOX\") entry))" "(((\"From\" . \"ann@example.org\") ...) . \"...\")"))
      (%ensure! c folder)
      (def uid (%uid c entry))
      (def found
        (List filter
          (fn (_ items)
            (if (str=? (let ((u (%item items "UID"))) (if (str? u) u "")) uid)
              (List any? (fn (_ p) (str=? (first p) "BODY")) items)
              #f))
          (List map (fn (_ u) (%items (%nth u 2))) (%named (%run c (list "UID FETCH" uid "(BODY.PEEK[])")) "FETCH"))))
      (when (null? found) (%fail "the server has no message for the entry" entry))
      (let ((b (%item (first found) "BODY"))) (if (str? b) b "")))

    (method flag! (self (param c VECTOR "A logged-in connection") (param folder LIST "A folder")
                        (param entry LIST "An entry") (param flags LIST "Flag symbols"))
      (doc "Give the message exactly these of the six flags: STORE adds the missing ones and takes off the others, so the server's keywords stay. A symbol that is not one of draft flagged passed replied seen trashed raises a label 'value."
        (returns LIST "The message's entry now")
        (sample "(Imap flag! c (list \"INBOX\") entry (list 'seen))" "(\"1700000000.41\" #f (seen) ...)"))
      (def want (%ordered flags))
      (%ensure! c folder)
      (def uid (%uid c entry))
      (def names (fn (_ syms) (Str8 join " " (List map (fn (_ s) (rest (Assoc find s %flag-names))) syms))))
      (def off (List filter (fn (_ s) (not (List includes? s want))) (List map first %flag-names)))
      (unless (null? want) (%run c (list "UID STORE" uid (Str8 str "+FLAGS.SILENT (" (names want) ")"))))
      (unless (null? off) (%run c (list "UID STORE" uid (Str8 str "-FLAGS.SILENT (" (names off) ")"))))
      (pair (first entry) (pair (%nth entry 1) (pair want (rest (rest (rest entry)))))))

    (method move! (self (param c VECTOR "A logged-in connection") (param from LIST "The folder it is in")
                        (param entry LIST "An entry") (param to LIST "The folder it goes to"))
      (doc "Move the message to another folder: MOVE where the server has it, else COPY, the deleted flag, and UID EXPUNGE of that one message where the server has UIDPLUS (with neither, it stays behind flagged trashed). The new entry's KEY comes from the server's COPYUID, nil where it names none."
        (returns LIST "The message's entry in its new folder")
        (sample "(Imap move! c (list \"INBOX\") entry (list \"Archive\"))" "(\"1700000500.9\" #f (seen) ...)"))
      (%ensure! c from)
      (def uid (%uid c entry))
      (def box (%astring (%mailbox c to)))
      (def r
        (if (%has? c "MOVE")
          (%run c (list "UID MOVE" uid box))
          (let ((copied (%run c (list "UID COPY" uid box))))
            (%run c (list "UID STORE" uid "+FLAGS.SILENT (\\Deleted)"))
            (when (%has? c "UIDPLUS") (%run c (list "UID EXPUNGE" uid)))
            copied)))
      (pair (%copied-key r) (rest entry)))

    (method create! (self (param c VECTOR "A logged-in connection") (param folder LIST "A folder"))
      (doc "Make the folder if it is not there. A folder there already is left as it is; any other refusal raises a label 'io."
        (returns LIST "The folder")
        (sample "(Imap create! c (list \"Archive\" \"2026\"))" "(\"Archive\" \"2026\")"))
      (def box (%mailbox c folder))
      (def r (%run-raw c (list "CREATE" (%astring box))))
      (unless (%ok? r)
        (when (null? (%leading (%run c (list "LIST" "\"\"" (%astring box))) "LIST"))
          (%io "CREATE refused" (rest r))))
      folder)

    (method search (self (param c VECTOR "A logged-in connection") (param folder LIST "A folder")
                         (param criteria STRING "Search keys as IMAP writes them: UNSEEN, FROM \"ann\", SINCE 1-Nov-2026"))
      (doc "UID SEARCH: the KEYs of the messages that match, in UID order, from SEARCH under IMAP4rev1 or ESEARCH under IMAP4rev2."
        (returns LIST "KEYs")
        (example "(Imap search (Imap client (Wire script \"* PREAUTH [CAPABILITY IMAP4rev1] hi\\r\\n* 3 EXISTS\\r\\n* OK [UIDVALIDITY 7] v\\r\\na1 OK done\\r\\n* SEARCH 9 4\\r\\na2 OK done\\r\\n\")) (list \"INBOX\") \"UNSEEN\")" "(\"7.4\" \"7.9\")"))
      (%ensure! c folder)
      (def r (%run c (list (Str8 append "UID SEARCH " criteria))))
      (def from-esearch
        (fn (_ u)
          (let go ((l u)) (match ((null? l) ()) ((if (%is? (first l) "ALL") (str? (%nth l 1)) #f) (%expand (%nth l 1))) (#t (go (rest l)))))))
      (def uids
        (List append
          (List fold (fn (_ acc u) (List append acc (List filter str? (rest u)))) () (%leading r "SEARCH"))
          (List fold (fn (_ acc u) (List append acc (from-esearch u))) () (%leading r "ESEARCH"))))
      (List map (fn (_ u) (Str8 str (obj-ref c 6) "." u)) (List sort %uid<? uids)))

    (method append (self (param c VECTOR "A logged-in connection") (param folder LIST "A folder")
                         (param text STRING "The message")
                         . (param flags LIST "Flag symbols to store it with"))
      (doc "APPEND the message to the folder, every line ended with CRLF, as a literal. Answers its entry (KEY #f FLAGS): KEY from the server's APPENDUID, nil where it names none."
        (returns LIST "The new message's entry")
        (sample "(Imap append c (list \"Sent\") text (list 'seen))" "(\"1700000000.42\" #f (seen))"))
      (def want (if (null? flags) () (%ordered (first flags))))
      (def box (%astring (%mailbox c folder)))
      (def flag-list (Str8 str "(" (Str8 join " " (List map (fn (_ s) (rest (Assoc find s %flag-names))) want)) ")"))
      (def r (%run c (List append (list "APPEND" box) (if (null? want) () (list flag-list)) (list (pair (lit literal) (%crlf text))))))
      (def code (%code (rest r) "APPENDUID"))
      (list (if (null? code) () (Str8 str (%nth code 1) "." (%nth code 2))) #f want))

    (method logout (self (param c VECTOR "A connection"))
      (doc "LOGOUT, then close the wire."
        (returns ANY "nil")
        (example "(null? (Imap logout (Imap client (Wire script \"* OK [CAPABILITY IMAP4rev1] hi\\r\\n* BYE bye\\r\\na1 OK done\\r\\n\"))))" "#t"))
      (%run c (list "LOGOUT"))
      (Wire close (obj-ref c 1))
      ())))

(doc (provide mail/imap Imap)
  "An IMAP client, IMAP4rev2 and IMAP4rev1, with mail/maildir's calls over a connection: folders, messages, read, flag!, move!, create!, plus search, append and the session's own calls."
  (example "(Imap capabilities (Imap client (Wire script \"* OK [CAPABILITY IMAP4rev1] hi\\r\\n\")))" "(\"IMAP4REV1\")"))
