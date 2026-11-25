; message.x -- Message: an Internet message (RFC 5322), its header and body.
;
; A message is (FIELDS . BODY): FIELDS a list of (NAME . VALUE) strings in the
; order they were written, BODY the text after the blank line.  NAME keeps the
; case it was written in; lookups ignore case.  VALUE is unfolded: a line break
; before a space or tab is taken out, the space or tab kept.
;
; A message is text: RFC 5322 has no NUL in a message, so a STRING carries one
; whole.  Binary content travels encoded (mail/mime).
;
; Parse reads a line ending as LF with or without a CR before it; write ends
; every header line with CRLF, as the wire wants, and leaves the body as it is.
(module mail/message)

(import x/core/doors char->int int+ int- int< int= str-byte-len str-byte-ref str-byte-sub)
(import x/codec/base64)
(import x/codec/bytes)

(def %fail (fn (_ what data) (Err raise (lit value) (Str8 append "Message: " what) data)))

(def %byte (fn (_ s i) (char->int (str-byte-ref s i))))

(def %wsp? (fn (_ c) (if (int= c 32) #t (int= c 9))))

; The line of s from at to its LF, without its line end, and where the next
; line starts: (LINE . NEXT).
(def %line-at
  (fn (_ s at n)
    (def nl (Bytes find (Bytes region s at (int- n at)) "\n"))
    (def end (if (null? nl) n (int+ at nl)))
    (def stop (if (int< at end) (if (int= (%byte s (int- end 1)) 13) (int- end 1) end) end))
    (pair (str-byte-sub s at (int- stop at)) (if (null? nl) n (int+ end 1)))))

; The first index of byte c in s from i, or nil.
(def %index
  (fn (self s c i n)
    (match ((int< i n) (if (int= (%byte s i) c) i (self s c (int+ i 1) n)))
           (#t ()))))

; s from i on, the spaces and tabs before it skipped.
(def %skip-wsp
  (fn (self s i n)
    (if (int< i n) (if (%wsp? (%byte s i)) (self s (int+ i 1) n) i) i)))

; A field line: (NAME . VALUE), the value's leading space taken off.
(def %field
  (fn (_ line)
    (def n (str-byte-len line))
    (def colon (%index line 58 0 n))
    (when (null? colon) (%fail "a header line with no colon" line))
    (def name (Str8 trim-right (str-byte-sub line 0 colon)))
    (when (int= (str-byte-len name) 0) (%fail "a header line with no field name" line))
    (def from (%skip-wsp line (int+ colon 1) n))
    (pair name (str-byte-sub line from (int- n from)))))

; The fields read up to the blank line, each continuation line joined to the
; field before it: (FIELDS . BODY-START).
(def %fields
  (fn (_ s n)
    (let go ((at 0) (acc ()))
      (if (int< at n)
        (let ((l (%line-at s at n)))
          (def line (first l))
          (match
            ((int= (str-byte-len line) 0) (pair (List reverse acc) (rest l)))
            ((%wsp? (%byte line 0))
              (do (when (null? acc) (%fail "the header starts with a continuation line" line))
                  (go (rest l) (pair (pair (first (first acc)) (Str8 append (rest (first acc)) line)) (rest acc)))))
            (#t (go (rest l) (pair (%field line) acc)))))
        (pair (List reverse acc) n)))))

(def %trim-values
  (fn (_ fields) (List map (fn (_ f) (pair (first f) (Str8 trim-right (rest f)))) fields)))

; "Name: value" as lines of at most 78 bytes where the value has a space or tab
; to break before; a word longer than that stays whole on its line.
(def %fold
  (fn (_ name value)
    (def line (Str8 append name ": " value))
    (def floor (int+ (str-byte-len name) 2))
    (let go ((s line) (out ()))
      (def n (str-byte-len s))
      (if (int< 78 n)
        (let ((at (let back ((i 78)) (match ((int< i floor) ()) ((%wsp? (%byte s i)) i) (#t (back (int- i 1)))))))
          (if (null? at)
            (Str8 join "\r\n" (List reverse (pair s out)))
            (go (str-byte-sub s at (int- n at)) (pair (str-byte-sub s 0 at) out))))
        (Str8 join "\r\n" (List reverse (pair s out)))))))

(def %hex-value
  (fn (_ c)
    (match ((if (int< 47 c) (int< c 58) #f) (int- c 48))
           ((if (int< 64 c) (int< c 71) #f) (int- c 55))
           ((if (int< 96 c) (int< c 103) #f) (int- c 87))
           (#t -1))))

; RFC 2047's Q encoding: _ a space, =XX a byte, anything else itself; nil when
; an = has no two hex digits after it.
(def %q-decode
  (fn (_ s)
    (def n (str-byte-len s))
    (let go ((i 0) (acc ()))
      (match
        ((int= i n) (bytes->str (List reverse acc)))
        ((int= (%byte s i) 95) (go (int+ i 1) (pair 32 acc)))
        ((int= (%byte s i) 61)
          (if (int< (int+ i 2) n)
            (let ((hi (%hex-value (%byte s (int+ i 1)))) (lo (%hex-value (%byte s (int+ i 2)))))
              (if (if (int< hi 0) #t (int< lo 0)) () (go (int+ i 3) (pair (int+ (* hi 16) lo) acc))))
            ()))
        (#t (go (int+ i 1) (pair (%byte s i) acc)))))))

; The encoded word at i, "=?charset?enc?text?=": (TEXT . END), or nil where
; there is none, it is not B or Q, or its text does not decode.
(def %word-at
  (fn (_ s i n)
    (def q1 (%index s 63 (int+ i 2) n))
    (def q2 (if (null? q1) () (%index s 63 (int+ q1 1) n)))
    (def q3 (if (null? q2) () (%index s 63 (int+ q2 1) n)))
    (if (if (null? q3) #t (if (int= (int- q2 q1) 2) (if (int< (int+ q3 1) n) (not (int= (%byte s (int+ q3 1)) 61)) #t) #t))
      ()
      (let ((enc (%byte s (int+ q1 1))) (text (str-byte-sub s (int+ q2 1) (int- q3 (int+ q2 1)))))
        (def decoded
          (match ((if (int= enc 66) #t (int= enc 98)) (guard (_ ()) (Base64 decode text)))
                 ((if (int= enc 81) #t (int= enc 113)) (%q-decode text))
                 (#t ())))
        (if (null? decoded) () (pair decoded (int+ q3 2)))))))

; s from i: spaces and tabs only, up to the next encoded word.
(def %gap-then-word?
  (fn (_ s i n)
    (def j (%skip-wsp s i n))
    (if (int< (int+ j 1) n) (if (int= (%byte s j) 61) (if (int= (%byte s (int+ j 1)) 63) (not (null? (%word-at s j n))) #f) #f) #f)))

(def %utf8-continuation? (fn (_ c) (if (int< 127 c) (int< c 192) #f)))

(def %plain?
  (fn (self s i n)
    (match ((int= i n) #t)
           ((int< (%byte s i) 32) #f)
           ((int< 126 (%byte s i)) #f)
           (#t (self s (int+ i 1) n)))))

; s cut into pieces of at most k bytes, never inside a UTF-8 sequence.
(def %utf8-pieces
  (fn (_ s k)
    (def n (str-byte-len s))
    (let go ((at 0) (out ()))
      (if (int< (int+ at k) n)
        (let ((cut (let back ((j (int+ at k))) (if (if (int< at j) (%utf8-continuation? (%byte s j)) #f) (back (int- j 1)) j))))
          (def end (if (int= cut at) (int+ at k) cut))
          (go end (pair (str-byte-sub s at (int- end at)) out)))
        (List reverse (pair (str-byte-sub s at (int- n at)) out))))))

; --- addresses

; s split at the commas that are outside quotes, angle brackets and comments.
(def %address-items
  (fn (_ s)
    (def n (str-byte-len s))
    (let go ((i 0) (from 0) (quoted #f) (angle 0) (paren 0) (out ()))
      (if (int= i n)
        (List reverse (pair (str-byte-sub s from (int- n from)) out))
        (let ((c (%byte s i)))
          (match
            ((if quoted (int= c 92) #f) (go (int+ i 2) from quoted angle paren out))
            ((int= c 34) (go (int+ i 1) from (not quoted) angle paren out))
            (quoted (go (int+ i 1) from quoted angle paren out))
            ((int= c 40) (go (int+ i 1) from quoted angle (int+ paren 1) out))
            ((if (int= c 41) (int< 0 paren) #f) (go (int+ i 1) from quoted angle (int- paren 1) out))
            ((int< 0 paren) (go (int+ i 1) from quoted angle paren out))
            ((int= c 60) (go (int+ i 1) from quoted (int+ angle 1) paren out))
            ((if (int= c 62) (int< 0 angle) #f) (go (int+ i 1) from quoted (int- angle 1) paren out))
            ((if (if (int= c 44) #t (int= c 59)) (int= angle 0) #f)
              (go (int+ i 1) (int+ i 1) quoted angle paren (pair (str-byte-sub s from (int- i from)) out)))
            (#t (go (int+ i 1) from quoted angle paren out))))))))

; s without its comments (parenthesised, nested) and with quoted strings
; unquoted.
(def %unquote
  (fn (_ s)
    (def n (str-byte-len s))
    (let go ((i 0) (quoted #f) (paren 0) (acc ()))
      (if (int= i n)
        (Str8 trim (bytes->str (List reverse acc)))
        (let ((c (%byte s i)))
          (match
            ((if quoted (if (int= c 92) (int< (int+ i 1) n) #f) #f) (go (int+ i 2) quoted paren (pair (%byte s (int+ i 1)) acc)))
            ((if (int= c 34) (int= paren 0) #f) (go (int+ i 1) (not quoted) paren acc))
            (quoted (go (int+ i 1) quoted paren (pair c acc)))
            ((int= c 40) (go (int+ i 1) quoted (int+ paren 1) acc))
            ((if (int= c 41) (int< 0 paren) #f) (go (int+ i 1) quoted (int- paren 1) acc))
            ((int< 0 paren) (go (int+ i 1) quoted paren acc))
            (#t (go (int+ i 1) quoted paren (pair c acc)))))))))

; The group's name taken off: "team: a@b" is "a@b".  A colon inside quotes or
; angle brackets is not a group's.
(def %ungroup
  (fn (_ s)
    (def n (str-byte-len s))
    (let go ((i 0) (quoted #f))
      (if (int= i n) s
        (let ((c (%byte s i)))
          (match
            ((int= c 34) (go (int+ i 1) (not quoted)))
            (quoted (go (int+ i 1) quoted))
            ((if (int= c 60) #t (int= c 64)) s)
            ((int= c 58) (str-byte-sub s (int+ i 1) (int- n (int+ i 1))))
            (#t (go (int+ i 1) quoted))))))))

(def %address
  (fn (_ item)
    (def s (%ungroup item))
    (def n (str-byte-len s))
    (def lt (%index s 60 0 n))
    (def gt (if (null? lt) () (%index s 62 (int+ lt 1) n)))
    (if (null? gt)
      (pair "" (%unquote s))
      (pair (%unquote (str-byte-sub s 0 lt)) (Str8 trim (str-byte-sub s (int+ lt 1) (int- gt (int+ lt 1))))))))

(def-class Message ()
  (doc "An Internet message (RFC 5322): (FIELDS . BODY), FIELDS a list of (NAME . VALUE) strings in order, BODY the text after the blank line. Names keep their case and are looked up without it; values are unfolded."
    (example "(Message field (Message parse \"Subject: hi\\r\\n\\r\\nbody\") \"subject\")" "\"hi\"")
    (see parse write field))
  (static
    (method parse (self (param text STRING "A message: header lines, a blank line, the body"))
      (doc "The message text as (FIELDS . BODY). A line ends at LF, a CR before it dropped. A continuation line (starting with a space or tab) joins the field before it; each value loses the space after its colon and at its end. Text with no blank line is all header. A header line with no colon raises a label 'value Err."
        (returns LIST "(FIELDS . BODY)")
        (example "(Message parse \"To: a@b\\r\\nSubject: two\\r\\n words\\r\\n\\r\\nhello\")" "(((\"To\" . \"a@b\") (\"Subject\" . \"two words\")) . \"hello\")")
        (example "(rest (Message parse \"To: a@b\\n\\nline one\\nline two\\n\"))" "\"line one\\nline two\\n\""))
      (def n (str-byte-len text))
      (def r (%fields text n))
      (pair (%trim-values (first r)) (str-byte-sub text (rest r) (int- n (rest r)))))

    (method make (self (param fields LIST "(NAME . VALUE) pairs") (param body STRING "The body"))
      (doc "A message of these fields and this body."
        (returns LIST "(FIELDS . BODY)")
        (example "(Message make (list (pair \"To\" \"a@b\")) \"hi\")" "(((\"To\" . \"a@b\")) . \"hi\")"))
      (pair fields body))

    (method fields (self (param m LIST "A message"))
      (doc "The message's (NAME . VALUE) pairs, in order."
        (returns LIST "(NAME . VALUE) pairs")
        (example "(Message fields (Message parse \"A: 1\\nB: 2\\n\\n\"))" "((\"A\" . \"1\") (\"B\" . \"2\"))"))
      (first m))

    (method body (self (param m LIST "A message"))
      (doc "The message's body: everything after the blank line."
        (returns STRING "The body")
        (example "(Message body (Message parse \"A: 1\\n\\nhi\"))" "\"hi\""))
      (rest m))

    (method field (self (param m LIST "A message") (param name STRING "A field name, any case"))
      (doc "The value of the first field of that name, or nil."
        (returns ANY "A STRING, or nil")
        (example "(Message field (Message parse \"From: a@b\\n\\n\") \"FROM\")" "\"a@b\"")
        (example "(null? (Message field (Message parse \"From: a@b\\n\\n\") \"To\"))" "#t"))
      (let go ((l (first m)))
        (match ((null? l) ())
               ((Str8 ci=? (first (first l)) name) (rest (first l)))
               (#t (go (rest l))))))

    (method values (self (param m LIST "A message") (param name STRING "A field name, any case"))
      (doc "The values of every field of that name, in order."
        (returns LIST "STRINGs")
        (example "(Message values (Message parse \"Received: a\\nTo: x\\nReceived: b\\n\\n\") \"received\")" "(\"a\" \"b\")"))
      (List map (fn (_ f) (rest f)) (List filter (fn (_ f) (Str8 ci=? (first f) name)) (first m))))

    (method add (self (param m LIST "A message") (param name STRING "The field name") (param value STRING "Its value"))
      (doc "The message with the field added after the others."
        (returns LIST "(FIELDS . BODY)")
        (example "(Message fields (Message add (Message make () \"\") \"To\" \"a@b\"))" "((\"To\" . \"a@b\"))"))
      (pair (List append (first m) (list (pair name value))) (rest m)))

    (method remove (self (param m LIST "A message") (param name STRING "A field name, any case"))
      (doc "The message without any field of that name."
        (returns LIST "(FIELDS . BODY)")
        (example "(Message fields (Message remove (Message parse \"A: 1\\nB: 2\\na: 3\\n\\n\") \"A\"))" "((\"B\" . \"2\"))"))
      (pair (List filter (fn (_ f) (not (Str8 ci=? (first f) name))) (first m)) (rest m)))

    (method set (self (param m LIST "A message") (param name STRING "The field name") (param value STRING "Its value"))
      (doc "The message with one field of that name: the first one's value replaced and the others removed, or the field added after the others when there was none."
        (returns LIST "(FIELDS . BODY)")
        (example "(Message fields (Message set (Message parse \"A: 1\\nB: 2\\na: 3\\n\\n\") \"A\" \"9\"))" "((\"A\" . \"9\") (\"B\" . \"2\"))"))
      (let go ((l (first m)) (seen #f) (acc ()))
        (match
          ((null? l) (pair (List reverse (if seen acc (pair (pair name value) acc))) (rest m)))
          ((Str8 ci=? (first (first l)) name)
            (go (rest l) #t (if seen acc (pair (pair (first (first l)) value) acc))))
          (#t (go (rest l) seen (pair (first l) acc))))))

    (method with-body (self (param m LIST "A message") (param body STRING "The new body"))
      (doc "The message with its fields and this body."
        (returns LIST "(FIELDS . BODY)")
        (example "(Message body (Message with-body (Message parse \"A: 1\\n\\nold\") \"new\"))" "\"new\""))
      (pair (first m) body))

    (method write (self (param m LIST "A message"))
      (doc "The message as text: each field \"Name: value\" folded before a space or tab so that a line is at most 78 bytes where it can be, each header line ended with CRLF, a blank line, then the body as it is."
        (returns STRING "The message text")
        (example "(Message write (Message make (list (pair \"To\" \"a@b\")) \"hi\"))" "\"To: a@b\\r\\n\\r\\nhi\""))
      (Str8 append
        (Str8 join "" (List map (fn (_ f) (Str8 append (%fold (first f) (rest f)) "\r\n")) (first m)))
        "\r\n"
        (rest m)))

    (method decode-words (self (param value STRING "A field value"))
      (doc "The value with its RFC 2047 encoded words (=?charset?B?...?= and =?charset?Q?...?=) decoded, and the space between two of them dropped. The bytes are answered in each word's own charset; a word that does not decode is left as it is."
        (returns STRING "The decoded value")
        (example "(Message decode-words \"=?utf-8?B?Y2Fmw6k=?= au lait\")" "\"café au lait\"")
        (example "(Message decode-words \"=?iso-8859-1?Q?a_b?= =?utf-8?Q?=63?=\")" "\"a bc\""))
      (def n (str-byte-len value))
      (let go ((i 0) (from 0) (out ()))
        (match
          ((int< (int+ i 1) n)
            (if (if (int= (%byte value i) 61) (int= (%byte value (int+ i 1)) 63) #f)
              (let ((w (%word-at value i n)))
                (if (null? w)
                  (go (int+ i 1) from out)
                  (let ((next (if (%gap-then-word? value (rest w) n) (%skip-wsp value (rest w) n) (rest w))))
                    (go next next (pair (first w) (pair (str-byte-sub value from (int- i from)) out))))))
              (go (int+ i 1) from out)))
          (#t (Str8 join "" (List reverse (pair (str-byte-sub value from (int- n from)) out)))))))

    (method encode-words (self (param text STRING "Text, UTF-8"))
      (doc "Text for a field value: as it is when it is printable ASCII, else UTF-8 B encoded words of at most 75 bytes each, a space between them, never cutting a UTF-8 sequence."
        (returns STRING "The value")
        (example "(Message encode-words \"plain\")" "\"plain\"")
        (example "(Message encode-words \"café\")" "\"=?utf-8?B?Y2Fmw6k=?=\""))
      (def n (str-byte-len text))
      (if (%plain? text 0 n)
        text
        (Str8 join " " (List map (fn (_ p) (Str8 append "=?utf-8?B?" (Base64 encode p) "?="))
                                 (%utf8-pieces text 45)))))

    (method addresses (self (param value STRING "An address list: To, Cc, From and the like"))
      (doc "The value's addresses as (DISPLAY . ADDRESS) pairs: commas inside quotes, angle brackets and comments do not separate, a group's name is dropped, quotes and comments are taken out of the display name, and an address with none has the display \"\"."
        (returns LIST "(DISPLAY . ADDRESS) pairs")
        (example "(Message addresses \"Ann <ann@a.org>, \\\"Bo, Jr\\\" <bo@b.org>, cy@c.org\")" "((\"Ann\" . \"ann@a.org\") (\"Bo, Jr\" . \"bo@b.org\") (\"\" . \"cy@c.org\"))")
        (example "(Message addresses \"team: a@x, b@y;\")" "((\"\" . \"a@x\") (\"\" . \"b@y\"))"))
      (List filter (fn (_ a) (int< 0 (str-byte-len (rest a))))
        (List map %address (%address-items value))))))

(doc (provide mail/message Message)
  "Internet messages (RFC 5322): parse a message into its fields and body, look fields up, change them, and write the message back as text; RFC 2047 encoded words and address lists."
  (example "(Message field (Message parse \"Subject: hi\\r\\n\\r\\n\") \"Subject\")" "\"hi\""))
