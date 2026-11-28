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

(import x/core/doors char->int int+ int- int* int< int= obj-ref obj-set! str-byte-len str-byte-ref str-byte-sub)
(import x/type/vector)
(import x/type/assoc)
(import x/sys/socket)
(import x/codec/bytes)
(import mail/wire)
(import mail/utf7)
(import mail/message)
(import mail/mime)
(import mail/maildir)
(import x/codec/base64)

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

; The size of the literal "{N}" or "{N+}" that ends a line, where it starts,
; and #t for "{N+}", which waits for no continuation: (N AT PLUS?), or nil.
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
              (if (null? size) () (list size i (not (str=? d digits))))))
          ((if (int< 47 (%byte line i)) (int< (%byte line i) 58) #f) (go (int- i 1)))
          ((int= (%byte line i) 43) (go (int- i 1)))
          (#t ())))
      ())))

; One response or command as it came: its lines, and the literals they
; announce, as (text . LINE) and (literal . BYTES) in order.  ahead, when not
; nil, is called (ahead SIZE LINE PLUS?) before each literal is read: for one
; the sender waits for (PLUS? #f) the server says go on, or raises to refuse it.
(def %response
  (fn (_ w ahead)
    (let go ((acc ()))
      (def line (Wire read-line w))
      (when (null? line) (%io "the connection closed" ()))
      (def at (%literal-at line))
      (if (null? at)
        (List reverse (pair (pair (lit text) line) acc))
        (do (unless (null? ahead) (ahead (first at) line (%nth at 2)))
            (go (pair (pair (lit literal) (Wire read-bytes w (first at)))
                      (pair (pair (lit text) (str-byte-sub line 0 (%nth at 1))) acc))))))))

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

(def %values (fn (_ w) (first (%parse (%tokens (%response w ())) (lit none)))))

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

; --- the server
;
; A server session is a vector: 1 the wire, 2 the opts, 3 the state: start,
; auth, selected or done, 4 the user, 5 the Maildir root, 6 the selected
; folder, 7 #t when it is read-only, 8 its messages, each (UID ENTRY) in
; sequence order, 9 its UIDVALIDITY, 10 its next UID, 11 the KEYs shown
; \Recent, 12 the sizes known, (KEY . N).  A message's text goes out with
; CRLF line ends, and every size and offset counts that text.

(def %s-state
  (fn (_ w opts)
    (def st (Vector make 12 0))
    (obj-set! st 1 w)
    (obj-set! st 2 opts)
    (obj-set! st 3 (lit start))
    (obj-set! st 4 ())
    (obj-set! st 5 ())
    (obj-set! st 6 ())
    (obj-set! st 7 #f)
    (obj-set! st 8 ())
    (obj-set! st 9 ())
    (obj-set! st 10 1)
    (obj-set! st 11 ())
    (obj-set! st 12 ())
    st))

; A tagged NO or BAD, raised from a command and written by the loop.
(def %s-no (fn (_ text) (Err raise (lit imap-no) text ())))

(def %s-bad (fn (_ text) (Err raise (lit imap-bad) text ())))

(def %s-say (fn (_ st line) (Wire write-line (obj-ref st 1) line)))

(def %s-untagged (fn (_ st text) (%s-say st (Str8 append "* " text))))

(def %s-max-size (fn (_ st) (let ((n (%opt (lit size) (obj-ref st 2)))) (if (null? n) 10485760 n))))

; s as an IMAP string: quoted where it can be, else a literal.
(def %s-str
  (fn (_ s)
    (def n (str-byte-len s))
    (if (let ok ((i 0)) (match ((int= i n) #t) ((int< 126 (%byte s i)) #f) ((int< (%byte s i) 32) #f) (#t (ok (int+ i 1)))))
      (Str8 str "\"" (Str8 replace "\"" "\\\"" (Str8 replace "\\" "\\\\" s)) "\"")
      (Str8 str "{" n "}\r\n" s))))

(def %s-nstr (fn (_ s) (if (str? s) (%s-str s) "NIL")))

(def %s-digits?
  (fn (_ s)
    (def n (if (str? s) (str-byte-len s) 0))
    (if (int= n 0) #f
      (let go ((i 0)) (match ((int= i n) #t) ((if (int< 47 (%byte s i)) (int< (%byte s i) 58) #f) (go (int+ i 1))) (#t #f))))))

(def %s-int (fn (_ s) (if (%s-digits? s) (%number s) (%s-bad "a number was expected"))))

; --- the session's capabilities

(def %s-login-ok?
  (fn (_ st)
    (if (null? (%opt (lit auth) (obj-ref st 2)))
      #f
      (if (Wire tls? (obj-ref st 1)) #t (%flag? (lit auth-in-clear) (obj-ref st 2))))))

(def %s-tls-offered?
  (fn (_ st) (if (null? (%opt (lit pem) (obj-ref st 2))) #f (not (Wire tls? (obj-ref st 1))))))

(def %s-caps
  (fn (_ st)
    (def pre (eq? (obj-ref st 3) (lit start)))
    (Str8 join " "
      (List append (list "IMAP4rev1" "LITERAL+" "SASL-IR" "UIDPLUS" "MOVE" "UNSELECT" "NAMESPACE")
                   (if (if pre (%s-tls-offered? st) #f) (list "STARTTLS") ())
                   (if pre (if (%s-login-ok? st) (list "AUTH=PLAIN") (list "LOGINDISABLED")) ())))))

; --- folders

; A mailbox name from the wire as a folder: INBOX in any case, else names
; split at "/" and out of modified UTF-7.
(def %s-folder
  (fn (_ name)
    (unless (if (str? name) (int< 0 (str-byte-len name)) #f) (%s-no "[NONEXISTENT] No folder by that name"))
    (if (Str8 ci=? name "INBOX")
      (list "INBOX")
      (let ((parts (%split name 47)))
        (when (List any? (fn (_ p) (int= (str-byte-len p) 0)) parts) (%s-no "[CANNOT] A folder name with an empty part"))
        (List map (fn (_ p) (Utf7 decode p)) parts)))))

; A folder's name on the wire, a "/" inside a name written in modified UTF-7.
(def %s-name
  (fn (_ folder)
    (if (if (null? (rest folder)) (Str8 ci=? (first folder) "INBOX") #f)
      "INBOX"
      (Str8 join "/" (List map (fn (_ p) (Utf7 encode-with p "/")) folder)))))

(def %s-exists?
  (fn (_ st folder)
    (def name (%s-name folder))
    (List any? (fn (_ f) (str=? (%s-name f) name)) (Maildir folders (obj-ref st 5)))))

(def %s-need-folder
  (fn (_ st name)
    (def folder (%s-folder name))
    (unless (%s-exists? st folder) (%s-no "[TRYCREATE] No folder by that name"))
    folder))

; pat matches name: "*" any run of bytes, "%" any run without "/".
(def %s-match?
  (fn (_ pat name)
    (def pn (str-byte-len pat))
    (def nn (str-byte-len name))
    (let go ((i 0) (j 0))
      (match
        ((int= i pn) (int= j nn))
        ((int= (%byte pat i) 42) (if (go (int+ i 1) j) #t (if (int< j nn) (go i (int+ j 1)) #f)))
        ((int= (%byte pat i) 37)
          (if (go (int+ i 1) j) #t (if (if (int< j nn) (not (int= (%byte name j) 47)) #f) (go i (int+ j 1)) #f)))
        ((int= j nn) #f)
        ((int= (%byte pat i) (%byte name j)) (go (int+ i 1) (int+ j 1)))
        (#t #f)))))

; Every folder's wire name as (NAME . SELECTABLE?), with a parent that is not a
; folder itself listed not selectable, INBOX first, then in byte order.
(def %s-listing
  (fn (_ st)
    (def names (List map %s-name (Maildir folders (obj-ref st 5))))
    (def parents
      (List fold
        (fn (_ acc n)
          (let go ((at (%split n 47)) (pre ()) (acc acc))
            (if (null? (rest at))
              acc
              (let ((p (if (null? pre) (first at) (Str8 str pre "/" (first at)))))
                (go (rest at) p (if (if (List any? (fn (_ x) (str=? x p)) names) #t (List any? (fn (_ x) (str=? x p)) acc)) acc (pair p acc)))))))
        () names))
    (def all (List append (List map (fn (_ n) (pair n #t)) names) (List map (fn (_ n) (pair n #f)) parents)))
    (def inbox (List filter (fn (_ p) (str=? (first p) "INBOX")) all))
    (List append inbox (List sort (fn (_ a b) (Str8 <? (first a) (first b))) (List filter (fn (_ p) (not (str=? (first p) "INBOX"))) all)))))

; --- the selected folder's messages

; The folder's messages as ((UID ENTRY) ...) in UID order, with its UIDVALIDITY
; and next UID: (VALIDITY NEXT RECORDS).
(def %s-records
  (fn (_ st folder)
    (def u (Maildir uids! (obj-ref st 5) folder))
    (def es (Maildir entries (obj-ref st 5) folder))
    (def joined
      (let go ((ps (List sort (fn (_ a b) (Str8 <? (rest a) (rest b))) (%nth u 2))) (l es) (acc ()))
        (match
          ((if (null? ps) #t (null? l)) acc)
          ((str=? (rest (first ps)) (first (first l))) (go (rest ps) (rest l) (pair (list (first (first ps)) (first l)) acc)))
          ((Str8 <? (rest (first ps)) (first (first l))) (go (rest ps) l acc))
          (#t (go ps (rest l) acc)))))
    (list (first u) (%nth u 1) (List sort (fn (_ a b) (int< (first a) (first b))) joined))))

(def %s-load!
  (fn (_ st folder)
    (def r (%s-records st folder))
    (obj-set! st 9 (first r))
    (obj-set! st 10 (%nth r 1))
    (obj-set! st 8 (%nth r 2))))

(def %s-recent? (fn (_ st rec) (List any? (fn (_ k) (str=? k (first (%nth rec 1)))) (obj-ref st 11))))

(def %s-has-flag? (fn (_ rec flag) (List any? (fn (_ f) (eq? f flag)) (%nth (%nth rec 1) 2))))

(def %s-flag-list
  (fn (_ st rec)
    (def names (List map (fn (_ s) (rest (Assoc find s %flag-names))) (%nth (%nth rec 1) 2)))
    (Str8 str "(" (Str8 join " " (if (%s-recent? st rec) (List append names (list "\\Recent")) names)) ")")))

(def %s-replace!
  (fn (_ st uid entry)
    (obj-set! st 8 (List map (fn (_ r) (if (int= (first r) uid) (list uid entry) r)) (obj-ref st 8)))))

; What changed in the folder since the session last looked: EXPUNGE for a
; message gone, highest first, EXISTS for a new count, FETCH FLAGS for flags
; changed by another program.
(def %s-sync!
  (fn (_ st)
    (def old (obj-ref st 8))
    (%s-load! st (obj-ref st 6))
    (def new (obj-ref st 8))
    (def find (fn (_ l uid) (List find (fn (_ r) (int= (first r) uid)) l)))
    (def kept
      (let go ((l (List reverse old)) (seq (List length old)) (acc ()))
        (match
          ((null? l) acc)
          ((not (null? (find new (first (first l))))) (go (rest l) (int- seq 1) (pair (first l) acc)))
          (#t (do (%s-untagged st (Str8 str seq " EXPUNGE")) (go (rest l) (int- seq 1) acc))))))
    (unless (int= (List length kept) (List length new)) (%s-untagged st (Str8 str (List length new) " EXISTS")))
    (let go ((l new) (seq 1))
      (unless (null? l)
        (let ((o (find kept (first (first l)))))
          (when (if (null? o) #f (not (equal? (%nth (%nth o 1) 2) (%nth (%nth (first l) 1) 2))))
            (%s-untagged st (Str8 str seq " FETCH (FLAGS " (%s-flag-list st (first l)) ")"))))
        (go (rest l) (int+ seq 1))))))

; A sequence set as (LO . HI) ranges, "*" standing for top.
(def %s-ranges
  (fn (_ set top)
    (unless (str? set) (%s-bad "a sequence set was expected"))
    (def num (fn (_ s) (if (str=? s "*") top (%s-int s))))
    (List map
      (fn (_ part)
        (def colon (Str8 index-of ":" part))
        (if (null? colon)
          (let ((n (num part))) (pair n n))
          (let ((a (num (str-byte-sub part 0 colon)))
                (b (num (str-byte-sub part (int+ colon 1) (int- (str-byte-len part) (int+ colon 1))))))
            (if (int< b a) (pair b a) (pair a b)))))
      (%split set 44))))

(def %s-in? (fn (_ n ranges) (List any? (fn (_ r) (if (int< n (first r)) #f (not (int< (rest r) n)))) ranges)))

; The messages a set names, by UID or by sequence number: ((SEQ . RECORD) ...).
(def %s-pick
  (fn (_ st set uid?)
    (def recs (obj-ref st 8))
    (def top (if (null? recs) 0 (if uid? (first (List last recs)) (List length recs))))
    (def ranges (%s-ranges set top))
    (let go ((l recs) (seq 1) (acc ()))
      (if (null? l)
        (List reverse acc)
        (go (rest l) (int+ seq 1) (if (%s-in? (if uid? (first (first l)) seq) ranges) (pair (pair seq (first l)) acc) acc))))))

; The numbers as a set: "3,5,9".
(def %s-set (fn (_ ns) (Str8 join "," (List map (fn (_ n) (Str8 str n)) ns))))

; A value computed once, on first call.
(def %s-once
  (fn (_ make)
    (def cell (Vector make 2 0))
    (obj-set! cell 1 #f)
    (fn (_)
      (unless (obj-ref cell 1) (do (obj-set! cell 2 (make)) (obj-set! cell 1 #t)))
      (obj-ref cell 2))))

(def %s-text (fn (_ st rec) (%crlf (Maildir read (obj-ref st 5) (obj-ref st 6) (%nth rec 1)))))

(def %s-size
  (fn (_ st rec text)
    (def key (first (%nth rec 1)))
    (def known (List find (fn (_ p) (str=? (first p) key)) (obj-ref st 12)))
    (if (null? known)
      (let ((n (str-byte-len (text)))) (obj-set! st 12 (pair (pair key n) (obj-ref st 12))) n)
      (rest known))))

(def %s-internal-date
  (fn (_ st rec) (rest (Assoc find (lit internal-date) (Maildir info (obj-ref st 5) (obj-ref st 6) (%nth rec 1)))))))

; --- a message's parts, as FETCH gives them

; Where a CRLF text's header ends: just past its blank line.
(def %s-header-end
  (fn (_ text)
    (if (Str8 starts? "\r\n" text) 2
      (let ((at (Str8 index-of "\r\n\r\n" text))) (if (null? at) (str-byte-len text) (int+ at 4))))))

; A raw header's fields as (NAME . LINES), LINES the field's lines with their
; CRLFs, a continuation line with the field before it.
(def %s-blocks
  (fn (_ head)
    (def n (str-byte-len head))
    (def line-end (fn (_ i) (let ((at (Str8 index-of "\r\n" (str-byte-sub head i (int- n i))))) (if (null? at) n (int+ i (int+ at 2))))))
    (let go ((i 0) (acc ()))
      (if (if (int< i n) (not (Str8 starts? "\r\n" (str-byte-sub head i (int- n i)))) #f)
        (let ((j (line-end i)))
          (def line (str-byte-sub head i (int- j i)))
          (if (if (pair? acc) (if (int= (%byte line 0) 32) #t (int= (%byte line 0) 9)) #f)
            (go j (pair (pair (first (first acc)) (Str8 append (rest (first acc)) line)) (rest acc)))
            (let ((colon (Str8 index-of ":" line)))
              (go j (pair (pair (if (null? colon) "" (Str8 trim (str-byte-sub line 0 colon))) line) acc)))))
        (List reverse acc)))))

(def %s-fields-text
  (fn (_ head names keep?)
    (def wanted? (fn (_ name) (List any? (fn (_ w) (if (str? w) (Str8 ci=? w name) #f)) names)))
    (Str8 append
      (Str8 join "" (List map rest (List filter (fn (_ b) (if keep? (wanted? (first b)) (not (wanted? (first b))))) (%s-blocks head))))
      "\r\n")))

(def %s-write-header
  (fn (_ m) (Str8 append (Str8 join "" (List map (fn (_ p) (Str8 str (first p) ": " (rest p) "\r\n")) (Message fields m))) "\r\n")))

(def %s-type
  (fn (_ m)
    (def v (Message field m "Content-Type"))
    (if (str? v) (Mime content-type v) (list "text/plain" (pair "charset" "us-ascii")))))

(def %s-multipart? (fn (_ m) (Str8 starts? "multipart/" (first (%s-type m)))))

(def %s-rfc822? (fn (_ m) (str=? (first (%s-type m)) "message/rfc822")))

(def %s-parts (fn (_ m) (guard (_ ()) (Mime parts m))))

; The part a path of part numbers names, or nil.
(def %s-part
  (fn (self m path)
    (match
      ((null? path) m)
      ((%s-multipart? m)
        (let ((parts (%s-parts m)) (k (first path)))
          (if (if (int< 0 k) (not (int< (List length parts) k)) #f) (self (%nth parts (int- k 1)) (rest path)) ())))
      ((%s-rfc822? m) (self (Message parse (Message body m)) path))
      ((int= (first path) 1) (self m (rest path)))
      (#t ()))))

; A section spec's text: "", HEADER, TEXT, HEADER.FIELDS, HEADER.FIELDS.NOT,
; MIME, each after part numbers or not.
(def %s-section
  (fn (_ text m items)
    (def spec (if (pair? items) (if (str? (first items)) (Str8 upcase (first items)) "") ""))
    (def names (if (pair? items) (if (pair? (rest items)) (%nth items 1) ()) ()))
    (def words (%split spec 46))
    (def path (List map %number (List filter %s-digits? words)))
    (def word (Str8 join "." (List filter (fn (_ w) (not (%s-digits? w))) words)))
    (def raw-head (fn (_ t) (str-byte-sub t 0 (%s-header-end t))))
    (def raw-body (fn (_ t) (let ((e (%s-header-end t))) (str-byte-sub t e (int- (str-byte-len t) e)))))
    (if (null? path)
      (match
        ((str=? word "") text)
        ((str=? word "HEADER") (raw-head text))
        ((str=? word "TEXT") (raw-body text))
        ((str=? word "HEADER.FIELDS") (%s-fields-text (raw-head text) (if (pair? names) names ()) #t))
        ((str=? word "HEADER.FIELDS.NOT") (%s-fields-text (raw-head text) (if (pair? names) names ()) #f))
        (#t (%s-bad "a section this server does not give")))
      (let ((p (%s-part m path)))
        (match
          ((null? p) "")
          ((str=? word "") (Message body p))
          ((str=? word "MIME") (%s-write-header p))
          ((not (%s-rfc822? p)) "")
          (#t (let ((inner (Message parse (Message body p))))
                (match
                  ((str=? word "HEADER") (%s-write-header inner))
                  ((str=? word "TEXT") (Message body inner))
                  ((str=? word "HEADER.FIELDS") (%s-fields-text (%s-write-header inner) names #t))
                  ((str=? word "HEADER.FIELDS.NOT") (%s-fields-text (%s-write-header inner) names #f))
                  (#t (%s-bad "a section this server does not give"))))))))))

; A section spec written back, as the FETCH response names it.
(def %s-spec-text
  (fn (_ items)
    (Str8 join " " (List map (fn (_ x) (if (pair? x) (Str8 str "(" (Str8 join " " (List filter str? x)) ")") (if (str? x) x ""))) items))))

; --- ENVELOPE and BODYSTRUCTURE

(def %s-last-at
  (fn (_ s) (let go ((i (int- (str-byte-len s) 1))) (match ((int< i 0) ()) ((int= (%byte s i) 64) i) (#t (go (int- i 1)))))))

(def %s-addresses
  (fn (_ m name)
    (def v (Message field m name))
    (def l (if (str? v) (Message addresses v) ()))
    (if (null? l)
      "NIL"
      (Str8 str "("
        (Str8 join ""
          (List map
            (fn (_ a)
              (def at (%s-last-at (rest a)))
              (def n (str-byte-len (rest a)))
              (Str8 str "(" (if (int= (str-byte-len (first a)) 0) "NIL" (%s-str (first a))) " NIL "
                        (%s-str (if (null? at) (rest a) (str-byte-sub (rest a) 0 at))) " "
                        (if (null? at) "NIL" (%s-str (str-byte-sub (rest a) (int+ at 1) (int- n (int+ at 1))))) ")"))
            l))
        ")"))))

(def %s-envelope
  (fn (_ m)
    (def f (fn (_ n) (%s-nstr (Message field m n))))
    (def from (%s-addresses m "From"))
    (def or-from (fn (_ n) (let ((a (%s-addresses m n))) (if (str=? a "NIL") from a))))
    (Str8 str "(" (f "Date") " " (f "Subject") " " from " " (or-from "Sender") " " (or-from "Reply-To") " "
              (%s-addresses m "To") " " (%s-addresses m "Cc") " " (%s-addresses m "Bcc") " "
              (f "In-Reply-To") " " (f "Message-ID") ")")))

(def %s-params
  (fn (_ ps)
    (if (null? ps) "NIL"
      (Str8 str "(" (Str8 join " " (List map (fn (_ p) (Str8 str (%s-str (Str8 upcase (first p))) " " (%s-str (rest p)))) ps)) ")"))))

; Lines in s, a last line without its newline counted.
(def %s-line-count
  (fn (_ s)
    (def n (str-byte-len s))
    (let go ((i 0) (k 0))
      (if (int= i n)
        (if (if (int< 0 n) (not (int= (%byte s (int- n 1)) 10)) #f) (int+ k 1) k)
        (go (int+ i 1) (if (int= (%byte s i) 10) (int+ k 1) k))))))

(def %s-disposition
  (fn (_ m)
    (def v (Message field m "Content-Disposition"))
    (if (str? v)
      (let ((d (Mime content-type v))) (Str8 str "(" (%s-str (Str8 upcase (first d))) " " (%s-params (rest d)) ")"))
      "NIL")))

; BODYSTRUCTURE with ext? #t, BODY without.
(def %s-structure
  (fn (self m ext?)
    (def ct (%s-type m))
    (def slash (Str8 index-of "/" (first ct)))
    (def major (Str8 upcase (if (null? slash) (first ct) (str-byte-sub (first ct) 0 slash))))
    (def minor (Str8 upcase (if (null? slash) "" (str-byte-sub (first ct) (int+ slash 1) (int- (str-byte-len (first ct)) (int+ slash 1))))))
    (def parts (if (str=? major "MULTIPART") (%s-parts m) ()))
    (if (pair? parts)
      (Str8 str "(" (Str8 join "" (List map (fn (_ p) (self p ext?)) parts)) " " (%s-str minor)
                (if ext? (Str8 str " " (%s-params (rest ct)) " " (%s-disposition m) " NIL NIL") "") ")")
      (let ((body (Message body m)))
        (Str8 str "(" (%s-str (if (pair? parts) "TEXT" major)) " " (%s-str minor) " " (%s-params (rest ct)) " "
                  (%s-nstr (Message field m "Content-ID")) " " (%s-nstr (Message field m "Content-Description")) " "
                  (%s-str (Str8 upcase (Mime encoding m))) " " (str-byte-len body)
                  (match
                    ((str=? major "TEXT") (Str8 str " " (%s-line-count body)))
                    ((%s-rfc822? m)
                      (let ((inner (Message parse body)))
                        (Str8 str " " (%s-envelope inner) " " (self inner ext?) " " (%s-line-count body))))
                    (#t ""))
                  (if ext? (Str8 str " NIL " (%s-disposition m) " NIL NIL") "") ")")))))

; --- FETCH

; The items after the set, macros spread: ((NAME SECTION PARTIAL) ...),
; SECTION the bracket's items or nil, PARTIAL (START . COUNT) or nil.
(def %s-fetch-items
  (fn (_ args)
    (def raw (if (if (pair? args) (if (null? (rest args)) (if (pair? (first args)) (not (%sect? (first args))) #f) #f) #f) (first args) args))
    (def spread
      (List fold
        (fn (_ acc x)
          (match
            ((%is? x "ALL") (List append acc (list "FLAGS" "INTERNALDATE" "RFC822.SIZE" "ENVELOPE")))
            ((%is? x "FAST") (List append acc (list "FLAGS" "INTERNALDATE" "RFC822.SIZE")))
            ((%is? x "FULL") (List append acc (list "FLAGS" "INTERNALDATE" "RFC822.SIZE" "ENVELOPE" "BODY")))
            (#t (List append acc (list x)))))
        () raw))
    (def partial
      (fn (_ x)
        (if (if (str? x) (Str8 starts? "<" x) #f)
          (let ((dot (Str8 index-of "." x)) (n (str-byte-len x)))
            (when (null? dot) (%s-bad "a partial is <START.COUNT>"))
            (pair (%s-int (str-byte-sub x 1 (int- dot 1))) (%s-int (str-byte-sub x (int+ dot 1) (int- n (int+ dot 2))))))
          ())))
    (let go ((l spread) (acc ()))
      (match
        ((null? l) (List reverse acc))
        ((not (str? (first l))) (%s-bad "a FETCH item was expected"))
        ((if (pair? (rest l)) (%sect? (first (rest l))) #f)
          (let ((p (if (pair? (rest (rest l))) (partial (first (rest (rest l)))) ())))
            (go (if (null? p) (rest (rest l)) (rest (rest (rest l))))
                (pair (list (Str8 upcase (first l)) (first (rest l)) p) acc))))
        (#t (go (rest l) (pair (list (Str8 upcase (first l)) () ()) acc)))))))

(def %s-sets-seen?
  (fn (_ items)
    (List any? (fn (_ i) (if (str=? (first i) "BODY") (pair? (%nth i 1)) (if (str=? (first i) "RFC822") #t (str=? (first i) "RFC822.TEXT")))) items)))

(def %s-cut
  (fn (_ s p)
    (if (null? p) s
      (let ((n (str-byte-len s)) (a (first p)))
        (if (int< n a) ""
          (str-byte-sub s a (if (int< (int- n a) (rest p)) (int- n a) (rest p))))))))

(def %s-fetch-one
  (fn (_ st seq rec items uid?)
    (def text (%s-once (fn (_) (%s-text st rec))))
    (def msg (%s-once (fn (_) (Message parse (text)))))
    (when (if (%s-sets-seen? items) (if (obj-ref st 7) #f (not (%s-has-flag? rec (lit seen)))) #f)
      (let ((e (Maildir flag! (obj-ref st 5) (obj-ref st 6) (%nth rec 1) (List append (%nth (%nth rec 1) 2) (list (lit seen))))))
        (%s-replace! st (first rec) e)
        (set! rec (list (first rec) e))
        (set! items (if (List any? (fn (_ i) (str=? (first i) "FLAGS")) items) items (List append items (list (list "FLAGS" () ())))))))
    (def piece
      (fn (_ i)
        (def name (first i))
        (match
          ((str=? name "UID") (Str8 str "UID " (first rec)))
          ((str=? name "FLAGS") (Str8 str "FLAGS " (%s-flag-list st rec)))
          ((str=? name "INTERNALDATE") (Str8 str "INTERNALDATE " (%s-str (%s-internal-date st rec))))
          ((str=? name "RFC822.SIZE") (Str8 str "RFC822.SIZE " (%s-size st rec text)))
          ((str=? name "ENVELOPE") (Str8 str "ENVELOPE " (%s-envelope (msg))))
          ((str=? name "BODYSTRUCTURE") (Str8 str "BODYSTRUCTURE " (%s-structure (msg) #t)))
          ((if (str=? name "BODY") (null? (%nth i 1)) #f) (Str8 str "BODY " (%s-structure (msg) #f)))
          ((if (pair? (%nth i 1)) (if (str=? name "BODY") #t (str=? name "BODY.PEEK")) #f)
            (let ((p (%nth i 2)))
              (Str8 str "BODY[" (%s-spec-text (rest (%nth i 1))) "]" (if (null? p) "" (Str8 str "<" (first p) ">")) " "
                        (%s-str (%s-cut (%s-section (text) (msg) (rest (%nth i 1))) p)))))
          ((str=? name "RFC822") (Str8 str "RFC822 " (%s-str (text))))
          ((str=? name "RFC822.HEADER") (Str8 str "RFC822.HEADER " (%s-str (%s-section (text) (msg) (list "HEADER")))))
          ((str=? name "RFC822.TEXT") (Str8 str "RFC822.TEXT " (%s-str (%s-section (text) (msg) (list "TEXT")))))
          (#t (%s-bad (Str8 append "a FETCH item this server does not give: " name))))))
    (def all (if (if uid? (not (List any? (fn (_ i) (str=? (first i) "UID")) items)) #f) (pair (list "UID" () ()) items) items))
    (%s-untagged st (Str8 str seq " FETCH (" (Str8 join " " (List map piece all)) ")"))))

(def %s-fetch
  (fn (_ st args uid?)
    (when (null? args) (%s-bad "FETCH takes a set and items"))
    (def items (%s-fetch-items (rest args)))
    (when (null? items) (%s-bad "FETCH takes items"))
    (List for-each (fn (_ p) (%s-fetch-one st (first p) (rest p) items uid?)) (%s-pick st (first args) uid?))))

; --- STORE, COPY, MOVE, EXPUNGE

(def %s-writable (fn (_ st) (when (obj-ref st 7) (%s-no "[READ-ONLY] The folder is selected read-only"))))

(def %s-store
  (fn (_ st args uid?)
    (%s-writable st)
    (when (int< (List length args) 3) (%s-bad "STORE takes a set, an item and flags"))
    (def item (Str8 upcase (%nth args 1)))
    (def silent? (Str8 ends? ".SILENT" item))
    (def how (match ((Str8 starts? "+" item) (lit add)) ((Str8 starts? "-" item) (lit take)) (#t (lit set))))
    (def base (if silent? (str-byte-sub item 0 (int- (str-byte-len item) 7)) item))
    (unless (List any? (fn (_ b) (str=? base b)) (list "FLAGS" "+FLAGS" "-FLAGS")) (%s-bad "STORE takes FLAGS, +FLAGS or -FLAGS"))
    (def given (%flags-of (List filter str? (if (pair? (%nth args 2)) (%nth args 2) (rest (rest args))))))
    (List for-each
      (fn (_ p)
        (def rec (rest p))
        (def now (%nth (%nth rec 1) 2))
        (def want
          (match
            ((eq? how (lit add)) (List append now given))
            ((eq? how (lit take)) (List filter (fn (_ f) (not (List includes? f given))) now))
            (#t given)))
        (def e (Maildir flag! (obj-ref st 5) (obj-ref st 6) (%nth rec 1) want))
        (%s-replace! st (first rec) e)
        (unless silent?
          (%s-untagged st (Str8 str (first p) " FETCH (FLAGS " (%s-flag-list st (list (first rec) e)) (if uid? (Str8 str " UID " (first rec)) "") ")"))))
      (%s-pick st (first args) uid?))))

(def %s-copy
  (fn (_ st args uid? move?)
    (when move? (%s-writable st))
    (when (int< (List length args) 2) (%s-bad "COPY and MOVE take a set and a folder"))
    (def to (%s-need-folder st (%nth args 1)))
    (def picked (%s-pick st (first args) uid?))
    (def root (obj-ref st 5))
    (def keys
      (List map
        (fn (_ p)
          (def e (%nth (rest p) 1))
          (first (if move?
                   (Maildir move! root (obj-ref st 6) e to)
                   (Maildir deliver root to (Maildir read root (obj-ref st 6) e) (%nth e 2)))))
        picked))
    (def u (Maildir uids! root to))
    (def dest (List map (fn (_ k) (let ((pr (List find (fn (_ x) (str=? (rest x) k)) (%nth u 2)))) (if (null? pr) 0 (first pr)))) keys))
    (def code (if (null? picked) "" (Str8 str "[COPYUID " (first u) " " (%s-set (List map (fn (_ p) (first (rest p))) picked)) " " (%s-set dest) "] ")))
    (when move?
      (%s-untagged st (Str8 append "OK " (Str8 append code "Moved")))
      (List for-each
        (fn (_ p)
          (%s-untagged st (Str8 str (first p) " EXPUNGE"))
          (obj-set! st 8 (List filter (fn (_ r) (not (int= (first r) (first (rest p))))) (obj-ref st 8))))
        (List reverse picked)))
    (when (str=? (%s-name to) (%s-name (obj-ref st 6))) (%s-sync! st))
    (if move? "MOVE completed" (Str8 append code "COPY completed"))))

; Remove the trashed messages, those of the set only when there is one; say
; EXPUNGE for each unless quiet?.
(def %s-expunge
  (fn (_ st set quiet?)
    (%s-writable st)
    (def targets
      (List filter (fn (_ p) (%s-has-flag? (rest p) (lit trashed)))
        (if (null? set) (%s-pick st "1:*" #f) (%s-pick st set #t))))
    (List for-each
      (fn (_ p)
        (Maildir delete! (obj-ref st 5) (obj-ref st 6) (%nth (rest p) 1))
        (unless quiet? (%s-untagged st (Str8 str (first p) " EXPUNGE")))
        (obj-set! st 8 (List filter (fn (_ r) (not (int= (first r) (first (rest p))))) (obj-ref st 8))))
      (List reverse targets))))

; --- SEARCH

(def %s-has?
  (fn (_ hay needle) (if (str? hay) (not (null? (Str8 index-of (Str8 downcase needle) (Str8 downcase hay)))) #f)))

; A date as a number YYYYMMDD: "1-Nov-2026", or an internal date's first word.
(def %s-day
  (fn (_ s)
    (def word (let ((sp (Str8 index-of " " s))) (if (null? sp) s (str-byte-sub s 0 sp))))
    (def parts (%split word 45))
    (unless (int= (List length parts) 3) (%s-bad "a date is D-Mon-YYYY"))
    (def month
      (let go ((l (list "jan" "feb" "mar" "apr" "may" "jun" "jul" "aug" "sep" "oct" "nov" "dec")) (i 1))
        (match ((null? l) (%s-bad "a date is D-Mon-YYYY")) ((Str8 ci=? (first l) (%nth parts 1)) i) (#t (go (rest l) (int+ i 1))))))
    (int+ (int* (%s-int (%nth parts 2)) 10000) (int+ (int* month 100) (%s-int (first parts))))))

; One search key from l: (PRED . REST), PRED (fn (_ seq rec m)) with m the
; message's lazy accessors (text msg).
(def %s-key
  (fn (self st l)
    (when (null? l) (%s-bad "a search key was expected"))
    (def k (first l))
    (def more (rest l))
    (def arg (fn (_) (if (pair? more) (first more) (%s-bad "a search key wants its argument"))))
    (def after (if (pair? more) (rest more) ()))
    (def flag (fn (_ sym want) (pair (fn (_ seq rec m) (if want (%s-has-flag? rec sym) (not (%s-has-flag? rec sym)))) more)))
    (def field (fn (_ name) (let ((s (arg))) (pair (fn (_ seq rec m) (%s-has? (Message field ((%nth m 1)) name) s)) after))))
    (def day (fn (_ test) (let ((d (%s-day (arg)))) (pair (fn (_ seq rec m) (test (%s-day (%s-internal-date st rec)) d)) after))))
    (match
      ((if (pair? k) (not (%sect? k)) #f) (pair (%s-keys st k) more))
      ((not (str? k)) (%s-bad "a search key was expected"))
      ((%s-digits? (first (%split k 44))) (let ((r (%s-ranges k (List length (obj-ref st 8))))) (pair (fn (_ seq rec m) (%s-in? seq r)) more)))
      ((Str8 starts? "*" k) (let ((r (%s-ranges k (List length (obj-ref st 8))))) (pair (fn (_ seq rec m) (%s-in? seq r)) more)))
      ((%is? k "ALL") (pair (fn (_ seq rec m) #t) more))
      ((%is? k "ANSWERED") (flag (lit replied) #t))
      ((%is? k "UNANSWERED") (flag (lit replied) #f))
      ((%is? k "DELETED") (flag (lit trashed) #t))
      ((%is? k "UNDELETED") (flag (lit trashed) #f))
      ((%is? k "DRAFT") (flag (lit draft) #t))
      ((%is? k "UNDRAFT") (flag (lit draft) #f))
      ((%is? k "FLAGGED") (flag (lit flagged) #t))
      ((%is? k "UNFLAGGED") (flag (lit flagged) #f))
      ((%is? k "SEEN") (flag (lit seen) #t))
      ((%is? k "UNSEEN") (flag (lit seen) #f))
      ((%is? k "RECENT") (pair (fn (_ seq rec m) (%s-recent? st rec)) more))
      ((%is? k "OLD") (pair (fn (_ seq rec m) (not (%s-recent? st rec))) more))
      ((%is? k "NEW") (pair (fn (_ seq rec m) (if (%s-recent? st rec) (not (%s-has-flag? rec (lit seen))) #f)) more))
      ((%is? k "KEYWORD") (let ((w (arg))) (pair (fn (_ seq rec m) (if (%is? w "$Forwarded") (%s-has-flag? rec (lit passed)) #f)) after)))
      ((%is? k "UNKEYWORD") (let ((w (arg))) (pair (fn (_ seq rec m) (if (%is? w "$Forwarded") (not (%s-has-flag? rec (lit passed))) #t)) after)))
      ((%is? k "FROM") (field "From"))
      ((%is? k "TO") (field "To"))
      ((%is? k "CC") (field "Cc"))
      ((%is? k "BCC") (field "Bcc"))
      ((%is? k "SUBJECT") (field "Subject"))
      ((%is? k "HEADER")
        (let ((name (arg)) (s (if (pair? after) (first after) (%s-bad "HEADER takes a name and a string"))))
          (pair (fn (_ seq rec m) (%s-has? (Message field ((%nth m 1)) name) s)) (rest after))))
      ((%is? k "BODY") (let ((s (arg))) (pair (fn (_ seq rec m) (%s-has? (Message body ((%nth m 1))) s)) after)))
      ((%is? k "TEXT") (let ((s (arg))) (pair (fn (_ seq rec m) (%s-has? ((first m)) s)) after)))
      ((%is? k "BEFORE") (day int<))
      ((%is? k "ON") (day int=))
      ((%is? k "SINCE") (day (fn (_ a b) (not (int< a b)))))
      ((%is? k "LARGER") (let ((n (%s-int (arg)))) (pair (fn (_ seq rec m) (int< n (%s-size st rec (first m)))) after)))
      ((%is? k "SMALLER") (let ((n (%s-int (arg)))) (pair (fn (_ seq rec m) (int< (%s-size st rec (first m)) n)) after)))
      ((%is? k "UID")
        (let ((recs (obj-ref st 8)))
          (def r (%s-ranges (arg) (if (null? recs) 0 (first (List last recs)))))
          (pair (fn (_ seq rec m) (%s-in? (first rec) r)) after)))
      ((%is? k "NOT") (let ((r (self st more))) (pair (fn (_ seq rec m) (not ((first r) seq rec m))) (rest r))))
      ((%is? k "OR")
        (let ((a (self st more)))
          (let ((b (self st (rest a))))
            (pair (fn (_ seq rec m) (if ((first a) seq rec m) #t ((first b) seq rec m))) (rest b)))))
      (#t (%s-bad (Str8 append "a search key this server does not take: " k))))))

; Every key of l, all of which must hold.
(def %s-keys
  (fn (_ st l)
    (def preds
      (let go ((l l) (acc ()))
        (if (null? l) (List reverse acc) (let ((r (%s-key st l))) (go (rest r) (pair (first r) acc))))))
    (fn (_ seq rec m) (List all? (fn (_ p) (p seq rec m)) preds))))

(def %s-search
  (fn (_ st args uid?)
    (def keys
      (if (%is? (first args) "CHARSET")
        (do (unless (if (%is? (%nth args 1) "UTF-8") #t (%is? (%nth args 1) "US-ASCII")) (%s-no "[BADCHARSET (UTF-8 US-ASCII)] That charset is not known"))
            (rest (rest args)))
        args))
    (def pred (%s-keys st keys))
    (def hits
      (let go ((l (obj-ref st 8)) (seq 1) (acc ()))
        (if (null? l)
          (List reverse acc)
          (let ((rec (first l)))
            (def text (%s-once (fn (_) (%s-text st rec))))
            (def msg (%s-once (fn (_) (Message parse (text)))))
            (go (rest l) (int+ seq 1) (if (pred seq rec (list text msg)) (pair (if uid? (first rec) seq) acc) acc))))))
    (%s-untagged st (Str8 join " " (pair "SEARCH" (List map (fn (_ n) (Str8 str n)) hits))))))

; --- the session's commands

(def %s-unplain
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

(def %s-log-in!
  (fn (_ st user password)
    (def ok ((%opt (lit auth) (obj-ref st 2)) user password))
    (unless ok (%s-no "[AUTHENTICATIONFAILED] Authentication failed"))
    (def store (%opt (lit store) (obj-ref st 2)))
    (def root (if (null? store) () (store user)))
    (unless (str? root) (%s-no "[UNAVAILABLE] No mail store for that user"))
    (obj-set! st 3 (lit auth))
    (obj-set! st 4 user)
    (obj-set! st 5 root)
    (Str8 str "[CAPABILITY " (%s-caps st) "] Logged in")))

(def %s-unselect! (fn (_ st) (do (obj-set! st 3 (lit auth)) (obj-set! st 6 ()) (obj-set! st 8 ()) (obj-set! st 11 ()) (obj-set! st 12 ()))))

(def %s-select
  (fn (_ st name read-only?)
    (%s-unselect! st)
    (def folder (%s-folder name))
    (unless (%s-exists? st folder) (%s-no "[NONEXISTENT] No folder by that name"))
    (def fresh (List filter (fn (_ e) (%nth e 1)) (Maildir entries (obj-ref st 5) folder)))
    (unless read-only? (List for-each (fn (_ e) (Maildir flag! (obj-ref st 5) folder e (%nth e 2))) fresh))
    (obj-set! st 6 folder)
    (obj-set! st 7 read-only?)
    (obj-set! st 11 (List map first fresh))
    (%s-load! st folder)
    (obj-set! st 3 (lit selected))
    (def recs (obj-ref st 8))
    (def unseen (let go ((l recs) (seq 1)) (match ((null? l) ()) ((%s-has-flag? (first l) (lit seen)) (go (rest l) (int+ seq 1))) (#t seq))))
    (%s-untagged st "FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)")
    (%s-untagged st (Str8 str (List length recs) " EXISTS"))
    (%s-untagged st (Str8 str (List length (List filter (fn (_ r) (%s-recent? st r)) recs)) " RECENT"))
    (unless (null? unseen) (%s-untagged st (Str8 str "OK [UNSEEN " unseen "] First unseen")))
    (%s-untagged st (Str8 str "OK [UIDVALIDITY " (obj-ref st 9) "] UIDs valid"))
    (%s-untagged st (Str8 str "OK [UIDNEXT " (obj-ref st 10) "] Predicted next UID"))
    (%s-untagged st (if read-only? "OK [PERMANENTFLAGS ()] Read-only"
                      "OK [PERMANENTFLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)] Flags kept"))
    (if read-only? "[READ-ONLY] EXAMINE completed" "[READ-WRITE] SELECT completed")))

(def %s-list
  (fn (_ st args lsub?)
    (when (int< (List length args) 2) (%s-bad "LIST takes a reference and a pattern"))
    (def ref (if (str? (first args)) (first args) ""))
    (def pat (if (str? (%nth args 1)) (%nth args 1) ""))
    (def verb (if lsub? "LSUB" "LIST"))
    (if (int= (str-byte-len pat) 0)
      (%s-untagged st (Str8 str verb " (\\Noselect) \"/\" \"\""))
      (let ((full (Str8 append ref pat)))
        (List for-each
          (fn (_ p)
            (when (if (%s-match? full (first p)) #t (if (str=? (first p) "INBOX") (%s-match? (Str8 upcase full) "INBOX") #f))
              (%s-untagged st (Str8 str verb " (" (if (rest p) "" "\\Noselect") ") \"/\" " (%s-str (first p))))))
          (%s-listing st))))))

(def %s-status
  (fn (_ st args)
    (when (int< (List length args) 2) (%s-bad "STATUS takes a folder and items"))
    (def folder (%s-folder (first args)))
    (unless (%s-exists? st folder) (%s-no "[NONEXISTENT] No folder by that name"))
    (def items (if (pair? (%nth args 1)) (%nth args 1) (rest args)))
    (def r (%s-records st folder))
    (def recs (%nth r 2))
    (def value
      (fn (_ k)
        (match
          ((%is? k "MESSAGES") (List length recs))
          ((%is? k "RECENT") (List length (List filter (fn (_ x) (%nth (%nth x 1) 1)) recs)))
          ((%is? k "UIDNEXT") (%nth r 1))
          ((%is? k "UIDVALIDITY") (first r))
          ((%is? k "UNSEEN") (List length (List filter (fn (_ x) (not (%s-has-flag? x (lit seen)))) recs)))
          (#t (%s-bad "a STATUS item this server does not give")))))
    (%s-untagged st (Str8 str "STATUS " (%s-str (%s-name folder)) " ("
                              (Str8 join " " (List map (fn (_ k) (Str8 str (Str8 upcase k) " " (value k))) (List filter str? items))) ")"))))

(def %s-append
  (fn (_ st args)
    (when (int< (List length args) 2) (%s-bad "APPEND takes a folder and a message"))
    (def folder (%s-need-folder st (first args)))
    (def text (List last args))
    (unless (str? text) (%s-bad "APPEND takes the message as a literal"))
    (def flags (if (pair? (%nth args 1)) (%flags-of (List filter str? (%nth args 1))) ()))
    (def given? (pair? (%nth args 1)))
    (def e (if given? (Maildir deliver (obj-ref st 5) folder text flags) (Maildir deliver (obj-ref st 5) folder text)))
    (def u (Maildir uids! (obj-ref st 5) folder))
    (def pr (List find (fn (_ x) (str=? (rest x) (first e))) (%nth u 2)))
    (when (if (eq? (obj-ref st 3) (lit selected)) (str=? (%s-name folder) (%s-name (obj-ref st 6))) #f) (%s-sync! st))
    (if (null? pr) "APPEND completed" (Str8 str "[APPENDUID " (first u) " " (first pr) "] APPEND completed"))))

(def %s-create
  (fn (_ st args)
    (def name (if (pair? args) (first args) ()))
    (def trimmed (if (if (str? name) (Str8 ends? "/" name) #f) (str-byte-sub name 0 (int- (str-byte-len name) 1)) name))
    (def folder (%s-folder trimmed))
    (when (if (null? (rest folder)) (Str8 ci=? (first folder) "INBOX") #f) (%s-no "[ALREADYEXISTS] INBOX is there"))
    (when (%s-exists? st folder) (%s-no "[ALREADYEXISTS] The folder is there"))
    (Maildir create! (obj-ref st 5) folder)
    "CREATE completed"))

(def %s-authenticate
  (fn (_ st args)
    (unless (%is? (first args) "PLAIN") (%s-no "[CANNOT] Only PLAIN is offered"))
    (unless (%s-login-ok? st) (%s-no "[PRIVACYREQUIRED] Not offered here"))
    (def b64
      (if (pair? (rest args))
        (if (str=? (%nth args 1) "=") "" (%nth args 1))
        (do (%s-say st "+ ")
            (let ((line (Wire read-line (obj-ref st 1))))
              (when (if (null? line) #t (str=? line "*")) (%s-bad "AUTHENTICATE cancelled"))
              line))))
    (def up (%s-unplain b64))
    (when (null? up) (%s-bad "AUTHENTICATE PLAIN takes authzid NUL user NUL password in base64"))
    (%s-log-in! st (first up) (rest up))))

(def %s-in (fn (_ st states) (unless (List any? (fn (_ s) (eq? s (obj-ref st 3))) states) (%s-bad "Not in this state"))))

; Run one command; answers the tagged OK's text.
(def %s-command
  (fn (_ st cmd args)
    (def in (list (lit auth) (lit selected)))
    (def sel (list (lit selected)))
    (match
      ((str=? cmd "CAPABILITY") (do (%s-untagged st (Str8 append "CAPABILITY " (%s-caps st))) "CAPABILITY completed"))
      ((str=? cmd "NOOP") (do (when (eq? (obj-ref st 3) (lit selected)) (%s-sync! st)) "NOOP completed"))
      ((str=? cmd "CHECK") (do (%s-in st sel) (%s-sync! st) "CHECK completed"))
      ((str=? cmd "LOGOUT") (do (%s-untagged st "BYE Logging out") (obj-set! st 3 (lit done)) "LOGOUT completed"))
      ((str=? cmd "STARTTLS")
        (do (%s-in st (list (lit start)))
            (unless (%s-tls-offered? st) (%s-bad "STARTTLS is not offered"))
            (lit starttls)))
      ((str=? cmd "LOGIN")
        (do (%s-in st (list (lit start)))
            (unless (%s-login-ok? st) (%s-no "[PRIVACYREQUIRED] LOGIN is disabled here"))
            (unless (if (str? (first args)) (str? (%nth args 1)) #f) (%s-bad "LOGIN takes a user and a password"))
            (%s-log-in! st (first args) (%nth args 1))))
      ((str=? cmd "AUTHENTICATE") (do (%s-in st (list (lit start))) (%s-authenticate st args)))
      ((str=? cmd "SELECT") (do (%s-in st in) (%s-select st (first args) #f)))
      ((str=? cmd "EXAMINE") (do (%s-in st in) (%s-select st (first args) #t)))
      ((str=? cmd "CLOSE") (do (%s-in st sel) (unless (obj-ref st 7) (%s-expunge st () #t)) (%s-unselect! st) "CLOSE completed"))
      ((str=? cmd "UNSELECT") (do (%s-in st sel) (%s-unselect! st) "UNSELECT completed"))
      ((str=? cmd "LIST") (do (%s-in st in) (%s-list st args #f) "LIST completed"))
      ((str=? cmd "LSUB") (do (%s-in st in) (%s-list st args #t) "LSUB completed"))
      ((str=? cmd "SUBSCRIBE") (do (%s-in st in) "SUBSCRIBE completed"))
      ((str=? cmd "UNSUBSCRIBE") (do (%s-in st in) "UNSUBSCRIBE completed"))
      ((str=? cmd "NAMESPACE") (do (%s-in st in) (%s-untagged st "NAMESPACE ((\"\" \"/\")) NIL NIL") "NAMESPACE completed"))
      ((str=? cmd "CREATE") (do (%s-in st in) (%s-create st args)))
      ((str=? cmd "STATUS") (do (%s-in st in) (%s-status st args) "STATUS completed"))
      ((str=? cmd "APPEND") (do (%s-in st in) (%s-append st args)))
      ((str=? cmd "EXPUNGE") (do (%s-in st sel) (%s-expunge st () #f) "EXPUNGE completed"))
      ((str=? cmd "FETCH") (do (%s-in st sel) (%s-fetch st args #f) "FETCH completed"))
      ((str=? cmd "STORE") (do (%s-in st sel) (%s-store st args #f) "STORE completed"))
      ((str=? cmd "COPY") (do (%s-in st sel) (%s-copy st args #f #f)))
      ((str=? cmd "MOVE") (do (%s-in st sel) (%s-copy st args #f #t)))
      ((str=? cmd "SEARCH") (do (%s-in st sel) (%s-search st args #f) "SEARCH completed"))
      ((str=? cmd "UID")
        (let ((sub (if (str? (first args)) (Str8 upcase (first args)) "")) (more (rest args)))
          (%s-in st sel)
          (match
            ((str=? sub "FETCH") (do (%s-fetch st more #t) "UID FETCH completed"))
            ((str=? sub "STORE") (do (%s-store st more #t) "UID STORE completed"))
            ((str=? sub "COPY") (%s-copy st more #t #f))
            ((str=? sub "MOVE") (%s-copy st more #t #t))
            ((str=? sub "SEARCH") (do (%s-search st more #t) "UID SEARCH completed"))
            ((str=? sub "EXPUNGE")
              (do (when (null? more) (%s-bad "UID EXPUNGE takes a set")) (%s-expunge st (first more) #f) "UID EXPUNGE completed"))
            (#t (%s-bad "UID takes FETCH, STORE, COPY, MOVE, SEARCH or EXPUNGE")))))
      (#t (%s-bad "Command not recognized")))))

; One command from the client, answered.
(def %s-serve-one
  (fn (_ st v)
    (def tag (first v))
    (if (if (str? tag) (pair? (rest v)) #f)
      (let ((r (guard (e (match
                           ((eq? (Err label e) (lit imap-no)) (pair (lit no) (Err text e)))
                           ((eq? (Err label e) (lit imap-bad)) (pair (lit bad) (Err text e)))
                           ((eq? (Err label e) (lit io)) (error e))
                           (#t (pair (lit no) (Str8 append "[SERVERBUG] " (Err text e))))))
                 (pair (lit ok) (%s-command st (if (str? (%nth v 1)) (Str8 upcase (%nth v 1)) "") (rest (rest v)))))))
        (match
          ((eq? (rest r) (lit starttls))
            (do (%s-say st (Str8 append tag " OK Begin TLS negotiation now"))
                (Wire tls-accept (obj-ref st 1) (%opt (lit pem) (obj-ref st 2)))))
          (#t (%s-say st (Str8 str tag " " (match ((eq? (first r) (lit ok)) "OK") ((eq? (first r) (lit no)) "NO") (#t "BAD")) " " (rest r))))))
      (if (str? tag) (%s-say st (Str8 append tag " BAD A command is a tag and a name")) (%s-untagged st "BAD A command is a tag and a name")))))

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
      ())

    (method serve (self (param w VECTOR "A wire to a client")
                        (param opts ALIST "(auth . FN); (store . FN); (pem . TEXT); (size . N); ('auth-in-clear)"))
      (doc "One IMAP4rev1 server session on the wire, over Maildir stores: the greeting, then commands to LOGOUT or the wire's end. (auth . (fn (_ user password))) says whether a login is good; without it no login is taken. (store . (fn (_ user))) answers the user's Maildir root. LOGIN and AUTHENTICATE PLAIN are offered under TLS only unless ('auth-in-clear), LOGINDISABLED otherwise. (pem . TEXT), a key and its certificates, turns on STARTTLS. (size . N) limits a literal (10 MB). Each folder keeps its UIDs in a file x-lib-mail-uids. Answers the wire, not closed."
        (returns VECTOR "The wire")
        (example "(Wire output (Imap serve (Wire script \"a1 CAPABILITY\\r\\na2 LOGOUT\\r\\n\") ()))" "\"* OK [CAPABILITY IMAP4rev1 LITERAL+ SASL-IR UIDPLUS MOVE UNSELECT NAMESPACE LOGINDISABLED] x-lib-mail IMAP ready\\r\\n* CAPABILITY IMAP4rev1 LITERAL+ SASL-IR UIDPLUS MOVE UNSELECT NAMESPACE LOGINDISABLED\\r\\na1 OK CAPABILITY completed\\r\\n* BYE Logging out\\r\\na2 OK LOGOUT completed\\r\\n\""))
      (def st (%s-state w opts))
      (def limit (%s-max-size st))
      (def ahead
        (fn (_ size line plus?)
          (match
            ((not (int< limit size)) (unless plus? (%s-say st "+ Ready for literal data")))
            (plus? (do (%s-untagged st "BYE A literal past the size limit") (obj-set! st 3 (lit done)) (%io "a literal past the size limit" line)))
            (#t (Err raise (lit imap-toobig) "a literal past the size limit" line)))))
      (%s-untagged st (Str8 str "OK [CAPABILITY " (%s-caps st) "] x-lib-mail IMAP ready"))
      (let go ()
        (unless (eq? (obj-ref st 3) (lit done))
          (let ((v (guard (e (match
                               ((eq? (Err label e) (lit imap-toobig))
                                 (do (%s-say st (Str8 append (first (%split (e data) 32)) " NO [TOOBIG] A literal past the size limit"))
                                     (lit again)))
                               ((eq? (Err label e) (lit value)) (do (%s-untagged st "BAD The command could not be read") (lit again)))
                               (#t ())))
                     (first (%parse (%tokens (%response w ahead)) (lit none))))))
            (match
              ((null? v) ())
              ((eq? v (lit again)) (go))
              (#t (do (%s-serve-one st v) (go)))))))
      w)))

(doc (provide mail/imap Imap)
  "An IMAP client, IMAP4rev2 and IMAP4rev1, with mail/maildir's calls over a connection: folders, messages, read, flag!, move!, create!, plus search, append and the session's own calls."
  (example "(Imap capabilities (Imap client (Wire script \"* OK [CAPABILITY IMAP4rev1] hi\\r\\n\")))" "(\"IMAP4REV1\")"))
