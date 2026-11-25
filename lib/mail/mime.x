; mime.x -- Mime: MIME bodies (RFC 2045, 2046), on mail/message's messages.
;
; A part is a message of its own: its fields (Content-Type and the rest) and
; its body.  A multipart body is split into its parts at its boundary lines,
; and built from parts with a fresh boundary.
;
; Decoding answers a STRING for text and a region (BUF START LEN) for any
; part: a decoded body can hold NULs, which a STRING ends at.
(module mail/mime)

(import x/core/doors char->int int+ int- int/ int< int= str-byte-len str-byte-ref str-byte-sub)
(import x/codec/base64)
(import x/codec/bytes)
(import mail/message)

(def %fail (fn (_ what data) (Err raise (lit value) (Str8 append "Mime: " what) data)))

(def %byte (fn (_ s i) (char->int (str-byte-ref s i))))

(def %wsp? (fn (_ c) (if (int= c 32) #t (int= c 9))))

; --- Content-Type and its parameters

; s split at the semicolons outside quotes.
(def %semis
  (fn (_ s)
    (def n (str-byte-len s))
    (let go ((i 0) (from 0) (quoted #f) (out ()))
      (match
        ((int= i n) (List reverse (pair (str-byte-sub s from (int- n from)) out)))
        ((if quoted (int= (%byte s i) 92) #f) (go (int+ i 2) from quoted out))
        ((int= (%byte s i) 34) (go (int+ i 1) from (not quoted) out))
        ((if quoted #f (int= (%byte s i) 59))
          (go (int+ i 1) (int+ i 1) quoted (pair (str-byte-sub s from (int- i from)) out)))
        (#t (go (int+ i 1) from quoted out))))))

; A quoted string's text, its backslashes taken out; anything else trimmed.
(def %param-value
  (fn (_ v)
    (def s (Str8 trim v))
    (def n (str-byte-len s))
    (if (if (int< 1 n) (if (int= (%byte s 0) 34) (int= (%byte s (int- n 1)) 34) #f) #f)
      (let go ((i 1) (acc ()))
        (match ((int< i (int- n 1))
                 (if (int= (%byte s i) 92)
                   (go (int+ i 2) (pair (%byte s (int+ i 1)) acc))
                   (go (int+ i 1) (pair (%byte s i) acc))))
               (#t (bytes->str (List reverse acc)))))
      s)))

(def %param
  (fn (_ item)
    (def eq (Str8 index-of "=" item))
    (if (null? eq) ()
      (pair (Str8 downcase (Str8 trim (str-byte-sub item 0 eq)))
            (%param-value (str-byte-sub item (int+ eq 1) (int- (str-byte-len item) (int+ eq 1))))))))

(def %lookup
  (fn (_ alist key)
    (let go ((l alist))
      (match ((null? l) ()) ((Str8 =? (first (first l)) key) (rest (first l))) (#t (go (rest l)))))))

; --- quoted-printable

(def %hex-value
  (fn (_ c)
    (match ((if (int< 47 c) (int< c 58) #f) (int- c 48))
           ((if (int< 64 c) (int< c 71) #f) (int- c 55))
           ((if (int< 96 c) (int< c 103) #f) (int- c 87))
           (#t -1))))

(def %hex-digits "0123456789ABCDEF")

; The quoted-printable text decoded into writer w: =XX a byte, = at a line's
; end a soft break, spaces and tabs before a line end dropped; an = with no
; two hex digits after it is kept.
(def %qp-decode-into
  (fn (_ w s)
    (def n (str-byte-len s))
    (def put (fn (_ c) (Bytes put-u8 w c)))
    ; where the spaces and tabs from i end: at a line end, the line end's
    ; index, else nil
    (def trailing-end
      (fn (self i)
        (match ((int= i n) n)
               ((%wsp? (%byte s i)) (self (int+ i 1)))
               ((int= (%byte s i) 13) i)
               ((int= (%byte s i) 10) i)
               (#t ()))))
    (let go ((i 0))
      (unless (int= i n)
        (let ((c (%byte s i)))
          (match
            ((%wsp? c)
              (let ((e (trailing-end i)))
                (if (null? e) (do (put c) (go (int+ i 1))) (go e))))
            ((int= c 61)
              (match
                ((if (int< (int+ i 1) n) (int= (%byte s (int+ i 1)) 10) #f) (go (int+ i 2)))
                ((if (int< (int+ i 2) n) (if (int= (%byte s (int+ i 1)) 13) (int= (%byte s (int+ i 2)) 10) #f) #f) (go (int+ i 3)))
                ((let ((e (trailing-end (int+ i 1)))) (if (null? e) #f (int< (int+ i 1) e)))
                  (go (trailing-end (int+ i 1))))
                ((int< (int+ i 2) n)
                  (let ((hi (%hex-value (%byte s (int+ i 1)))) (lo (%hex-value (%byte s (int+ i 2)))))
                    (if (if (int< hi 0) #t (int< lo 0))
                      (do (put c) (go (int+ i 1)))
                      (do (put (int+ (* hi 16) lo)) (go (int+ i 3))))))
                (#t (do (put c) (go (int+ i 1))))))
            (#t (do (put c) (go (int+ i 1))))))))))

; The bytes of region r as quoted-printable lines of at most 76, each line
; end of the input a CRLF.
(def %qp-encode
  (fn (_ r)
    (def n (Bytes length r))
    (def at (fn (_ i) (Bytes ref r i)))
    (def line-end? (fn (_ i) (match ((int= i n) #t) ((int= (at i) 10) #t) ((int= (at i) 13) (if (int< (int+ i 1) n) (int= (at (int+ i 1)) 10) #f)) (#t #f))))
    (def hex (fn (_ c) (Str8 append "=" (str-byte-sub %hex-digits (int/ c 16) 1) (str-byte-sub %hex-digits (% c 16) 1))))
    (let go ((i 0) (col 0) (out ()))
      (if (int= i n)
        (Str8 join "" (List reverse out))
        (let ((c (at i)))
          (match
            ((int= c 10) (go (int+ i 1) 0 (pair "\r\n" out)))
            ((if (int= c 13) (line-end? i) #f) (go (int+ i 2) 0 (pair "\r\n" out)))
            (#t
              (let ((piece (match ((if (%wsp? c) (line-end? (int+ i 1)) #f) (hex c))
                                  ((%wsp? c) (bytes->str (list c)))
                                  ((int= c 61) (hex c))
                                  ((if (int< 32 c) (int< c 127) #f) (bytes->str (list c)))
                                  (#t (hex c)))))
                (def w (str-byte-len piece))
                (if (int< 75 (int+ col w))
                  (go (int+ i 1) w (pair piece (pair "=\r\n" out)))
                  (go (int+ i 1) (int+ col w) (pair piece out)))))))))))

; Base64 text cut into CRLF-ended lines of 76.
(def %b64-lines
  (fn (_ data)
    (def r (Base64 encode-region data))
    (def text (str-byte-sub (first r) (first (rest r)) (first (rest (rest r)))))
    (def n (str-byte-len text))
    (let go ((at 0) (out ()))
      (if (int< at n)
        (let ((k (if (int< n (int+ at 76)) (int- n at) 76)))
          (go (int+ at k) (pair "\r\n" (pair (str-byte-sub text at k) out))))
        (Str8 join "" (List reverse out))))))

; --- multipart

; The offsets in body of the boundary lines, each (START . AFTER . CLOSE?):
; START where "--boundary" begins, AFTER past its line end, CLOSE? #t for the
; closing "--boundary--".  A boundary line starts a line and may end in
; spaces or tabs.
(def %delimiters
  (fn (_ body boundary)
    (def n (str-byte-len body))
    (def dash (Str8 append "--" boundary))
    (def k (str-byte-len dash))
    (def line-after
      (fn (self i)
        (match ((int= i n) n)
               ((int= (%byte body i) 10) (int+ i 1))
               (#t (self (int+ i 1))))))
    (def rest-blank?
      (fn (self i)
        (match ((int= i n) #t)
               ((int= (%byte body i) 10) #t)
               ((int= (%byte body i) 13) (self (int+ i 1)))
               ((%wsp? (%byte body i)) (self (int+ i 1)))
               (#t #f))))
    (let go ((from 0) (out ()))
      (def hit (if (int< from n) (Bytes find (Bytes region body from (int- n from)) dash) ()))
      (if (null? hit)
        (List reverse out)
        (let ((at (int+ from hit)))
          (def after (int+ at k))
          (def close? (if (int< (int+ after 1) n) (if (int= (%byte body after) 45) (int= (%byte body (int+ after 1)) 45) #f) #f))
          (def tail (if close? (int+ after 2) after))
          (if (if (if (int= at 0) #t (int= (%byte body (int- at 1)) 10)) (rest-blank? tail) #f)
            (if close?
              (List reverse (pair (list at (line-after tail) #t) out))
              (go (line-after tail) (pair (list at (line-after tail) #f) out)))
            (go (int+ at 1) out)))))))

; Where the text before a boundary line ends: the line end before it is the
; boundary's, not the part's.
(def %part-end
  (fn (_ body at)
    (match ((int= at 0) 0)
           ((if (int< 1 at) (int= (%byte body (int- at 2)) 13) #f) (int- at 2))
           (#t (int- at 1)))))

(def-class Mime ()
  (doc "MIME bodies (RFC 2045, 2046) on mail/message's messages: Content-Type and its parameters, a part's body decoded from base64 or quoted-printable, a multipart body split into its parts, and parts made and joined."
    (example "(Mime type (Message parse \"Content-Type: Text/HTML; charset=utf-8\\n\\n\"))" "\"text/html\"")
    (see content-type decode parts multipart))
  (static
    (method content-type (self (param value STRING "A Content-Type or Content-Disposition value"))
      (doc "The value as (TYPE . PARAMETERS): TYPE in lower case, PARAMETERS (NAME . VALUE) pairs with each name in lower case and a quoted value unquoted."
        (returns LIST "(TYPE . PARAMETERS)")
        (example "(Mime content-type \"multipart/Mixed; Boundary=\\\"a;b\\\"; x=1\")" "(\"multipart/mixed\" (\"boundary\" . \"a;b\") (\"x\" . \"1\"))"))
      (def items (%semis value))
      (pair (Str8 downcase (Str8 trim (first items)))
            (List filter (fn (_ p) (not (null? p))) (List map %param (rest items)))))

    (method type (self (param m LIST "A message or part"))
      (doc "Its content type in lower case, text/plain when it has no Content-Type."
        (returns STRING "TYPE/SUBTYPE")
        (example "(Mime type (Message parse \"A: 1\\n\\n\"))" "\"text/plain\""))
      (def v (Message field m "Content-Type"))
      (if (null? v) "text/plain" (first (self content-type v))))

    (method param (self (param m LIST "A message or part") (param name STRING "A Content-Type parameter, any case"))
      (doc "The value of one of its Content-Type parameters, or nil."
        (returns ANY "A STRING, or nil")
        (example "(Mime param (Message parse \"Content-Type: text/plain; CharSet=utf-8\\n\\n\") \"charset\")" "\"utf-8\""))
      (def v (Message field m "Content-Type"))
      (if (null? v) () (%lookup (rest (self content-type v)) (Str8 downcase name))))

    (method filename (self (param m LIST "A part"))
      (doc "The part's file name: Content-Disposition's filename, else Content-Type's name, else nil. An encoded word in it is decoded."
        (returns ANY "A STRING, or nil")
        (example "(Mime filename (Message parse \"Content-Disposition: attachment; filename=\\\"a b.txt\\\"\\n\\n\"))" "\"a b.txt\""))
      (def d (Message field m "Content-Disposition"))
      (def from-d (if (null? d) () (%lookup (rest (self content-type d)) "filename")))
      (def name (if (null? from-d) (self param m "name") from-d))
      (if (null? name) () (Message decode-words name)))

    (method encoding (self (param m LIST "A message or part"))
      (doc "Its Content-Transfer-Encoding in lower case, 7bit when it has none."
        (returns STRING "7bit, 8bit, binary, base64 or quoted-printable")
        (example "(Mime encoding (Message parse \"Content-Transfer-Encoding: Base64\\n\\n\"))" "\"base64\""))
      (def v (Message field m "Content-Transfer-Encoding"))
      (if (null? v) "7bit" (Str8 downcase (Str8 trim v))))

    (method decode-region (self (param m LIST "A message or part"))
      (doc "Its body decoded from its transfer encoding, as a region (BUF 0 LEN): base64 and quoted-printable decoded, 7bit, 8bit and binary as they are. Any other encoding raises a label 'value Err."
        (returns LIST "(BUF 0 LEN)")
        (example "(Bytes hex (Mime decode-region (Message parse \"Content-Transfer-Encoding: base64\\n\\nAGE=\\n\")))" "\"0061\""))
      (def enc (self encoding m))
      (def body (Message body m))
      (match
        ((Str8 =? enc "base64") (Base64 decode-region body))
        ((Str8 =? enc "quoted-printable")
          (let ((w (Bytes writer))) (do (%qp-decode-into w body) (Bytes written w))))
        ((List includes? enc (list "7bit" "8bit" "binary")) (Bytes of body))
        (#t (%fail "an unknown transfer encoding" enc))))

    (method decode (self (param m LIST "A message or part"))
      (doc "Its body decoded from its transfer encoding, as a STRING: for text, which has no NUL. Binary takes decode-region."
        (returns STRING "The decoded body")
        (example "(Mime decode (Message parse \"Content-Transfer-Encoding: quoted-printable\\n\\ncaf=C3=A9 =\\nau lait\"))" "\"café au lait\""))
      (def r (self decode-region m))
      (str-byte-sub (first r) (first (rest r)) (first (rest (rest r)))))

    (method quoted-printable (self (param data ANY "The bytes: a region (BUF START LEN), or a STRING"))
      (doc "The bytes as quoted-printable (RFC 2045 6.7): printable ASCII as it is, = and other bytes as =XX, a space or tab before a line end encoded, each line end a CRLF, and soft breaks keeping a line to 76."
        (returns STRING "Quoted-printable text")
        (example "(Mime quoted-printable \"café = 1 \")" "\"caf=C3=A9 =3D 1=20\""))
      (%qp-encode (Bytes of data)))

    (method text (self (param body STRING "Text, UTF-8"))
      (doc "A text/plain part in UTF-8: 7bit when the text is ASCII with lines of at most 76 bytes, else quoted-printable."
        (returns LIST "A part")
        (example "(Message fields (Mime text \"hi\"))" "((\"Content-Type\" . \"text/plain; charset=utf-8\") (\"Content-Transfer-Encoding\" . \"7bit\"))"))
      (def qp (%qp-encode (Bytes of body)))
      (def plain? (Str8 =? qp (Str8 replace "\n" "\r\n" (Str8 replace "\r\n" "\n" body))))
      (Message make
        (list (pair "Content-Type" "text/plain; charset=utf-8")
              (pair "Content-Transfer-Encoding" (if plain? "7bit" "quoted-printable")))
        (if plain? body qp)))

    (method attachment (self (param name STRING "The file name")
                             (param type STRING "Its content type, such as application/pdf")
                             (param data ANY "Its bytes: a region (BUF START LEN), or a STRING"))
      (doc "A base64 part carrying a file as an attachment, its name in Content-Type and Content-Disposition, encoded when it is not plain ASCII."
        (returns LIST "A part")
        (example "(Message body (Mime attachment \"a.bin\" \"application/octet-stream\" (Bytes of-hex \"0061\")))" "\"AGE=\\r\\n\""))
      (def q (Str8 append "\"" (Str8 replace "\"" "\\\"" (Message encode-words name)) "\""))
      (Message make
        (list (pair "Content-Type" (Str8 append type "; name=" q))
              (pair "Content-Disposition" (Str8 append "attachment; filename=" q))
              (pair "Content-Transfer-Encoding" "base64"))
        (%b64-lines (Bytes of data))))

    (method parts (self (param m LIST "A multipart message or part"))
      (doc "Its body's parts, each a message: the text between one boundary line and the next, the line end before a boundary line the boundary's. The preamble and the epilogue are not parts. A part with no Content-Type of multipart raises a label 'value Err, as does one with no boundary."
        (returns LIST "Parts")
        (example "(List map (fn (_ p) (Message body p)) (Mime parts (Message parse \"Content-Type: multipart/mixed; boundary=b\\n\\n--b\\n\\none\\n--b\\n\\ntwo\\n--b--\\n\")))" "(\"one\" \"two\")"))
      (unless (Str8 starts? "multipart/" (self type m)) (%fail "not a multipart" (self type m)))
      (def boundary (self param m "boundary"))
      (when (null? boundary) (%fail "a multipart with no boundary" ()))
      (def body (Message body m))
      (let go ((ds (%delimiters body boundary)) (out ()))
        (if (if (null? ds) #t (first (rest (rest (first ds)))))
          (List reverse out)
          (let ((from (first (rest (first ds)))))
            (def end (if (null? (rest ds)) (str-byte-len body) (%part-end body (first (first (rest ds))))))
            (go (rest ds) (pair (Message parse (str-byte-sub body from (int- end from))) out))))))

    (method multipart (self (param subtype STRING "mixed, alternative, related ...") (param parts LIST "Parts"))
      (doc "A message whose body is the parts under a fresh random boundary, with MIME-Version and Content-Type multipart/SUBTYPE. Add From, To and Subject to it with Message add."
        (returns LIST "A message")
        (example "(List length (Mime parts (Mime multipart \"mixed\" (list (Mime text \"a\") (Mime text \"b\")))))" "2"))
      (def boundary (Str8 append "=_" (Bytes hex (Bytes random 12))))
      (Message make
        (list (pair "MIME-Version" "1.0")
              (pair "Content-Type" (Str8 append "multipart/" subtype "; boundary=\"" boundary "\"")))
        (Str8 append
          (Str8 join "" (List map (fn (_ p) (Str8 append "--" boundary "\r\n" (Message write p) "\r\n")) parts))
          "--" boundary "--\r\n")))))

(doc (provide mail/mime Mime)
  "MIME (RFC 2045, 2046) on mail/message: Content-Type parameters, base64 and quoted-printable bodies decoded and made, multipart bodies split into their parts and built from them."
  (example "(Mime type (Message parse \"Content-Type: text/html\\n\\n\"))" "\"text/html\""))
