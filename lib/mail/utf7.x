; utf7.x -- Utf7: IMAP's modified UTF-7 (RFC 3501 5.1.3), for mailbox names.
;
; Printable ASCII stands for itself, "&" written "&-"; a run of anything else
; is its UTF-16 in base64 (with "," for "/"), unpadded, between "&" and "-".
; encode-with writes some printable bytes as runs too, for a store that needs
; them kept out of a name: mail/maildir writes "." and "/" that way.
(module mail/utf7)

(import x/core/doors char->int int& int+ int- int< int<< int= int>> int| str-byte-len str-byte-ref str-byte-sub)
(import x/codec/utf8 utf8-decode utf8-encode)

(def %byte (fn (_ s i) (char->int (str-byte-ref s i))))

(def %b64 "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,")

(def %b64-value
  (fn (_ c)
    (match
      ((if (int< 64 c) (int< c 91) #f) (int- c 65))
      ((if (int< 96 c) (int< c 123) #f) (int- c 71))
      ((if (int< 47 c) (int< c 58) #f) (int+ c 4))
      ((int= c 43) 62)
      ((int= c 44) 63)
      (#t -1))))

; The code points as UTF-16 bytes, most significant first.
(def %utf16-bytes
  (fn (_ cps)
    (def unit (fn (_ u acc) (pair (int& u 255) (pair (int>> u 8) acc))))
    (let go ((l cps) (acc ()))
      (match
        ((null? l) (List reverse acc))
        ((int< (first l) 65536) (go (rest l) (unit (first l) acc)))
        (#t (let ((v (int- (first l) 65536)))
              (go (rest l) (unit (int| 56320 (int& v 1023)) (unit (int| 55296 (int>> v 10)) acc)))))))))

; The bytes as base64 in the modified alphabet, unpadded.
(def %b64-encode
  (fn (_ bytes)
    (let go ((l bytes) (bits 0) (n 0) (acc ()))
      (match
        ((int< 5 n)
          (let ((k (int- n 6)))
            (go l (int& bits (int- (int<< 1 k) 1)) k (pair (%byte %b64 (int>> bits k)) acc))))
        ((null? l)
          (List reverse (if (int= n 0) acc (pair (%byte %b64 (int<< bits (int- 6 n))) acc))))
        (#t (go (rest l) (int| (int<< bits 8) (first l)) (int+ n 8) acc))))))

(def %encode
  (fn (_ name specials)
    (def n (str-byte-len name))
    (def special? (fn (_ c) (List any? (fn (_ s) (int= s c)) specials)))
    ; a byte written as itself: printable ASCII but "&" and the specials
    (def direct? (fn (_ c) (match ((int< c 32) #f) ((int< 126 c) #f) ((int= c 38) #f) (#t (not (special? c))))))
    (def cps-from
      (fn (self i acc)
        (match
          ((int= i n) (pair (List reverse acc) i))
          ((direct? (%byte name i)) (pair (List reverse acc) i))
          ((int= (%byte name i) 38) (pair (List reverse acc) i))
          ((special? (%byte name i)) (self (int+ i 1) (pair (%byte name i) acc)))
          (#t (let ((d (utf8-decode name i))) (self (rest d) (pair (first d) acc)))))))
    (let go ((i 0) (acc ()))
      (match
        ((int= i n) (bytes->str (List reverse acc)))
        ((int= (%byte name i) 38) (go (int+ i 1) (pair 45 (pair 38 acc))))
        ((direct? (%byte name i)) (go (int+ i 1) (pair (%byte name i) acc)))
        (#t
          (let ((run (cps-from i ())))
            (go (rest run)
                (pair 45 (List append (List reverse (%b64-encode (%utf16-bytes (first run)))) (pair 38 acc))))))))))

; The base64 between "&" and "-" as UTF-8 bytes, or nil when it is not UTF-16.
(def %decode-run
  (fn (_ s from to)
    (def bytes
      (let go ((i from) (bits 0) (n 0) (acc ()))
        (match
          ((int< 7 n)
            (let ((k (int- n 8)))
              (go i (int& bits (int- (int<< 1 k) 1)) k (pair (int>> bits k) acc))))
          ((int= i to) (List reverse acc))
          (#t (let ((v (%b64-value (%byte s i))))
                (if (int< v 0) (lit bad) (go (int+ i 1) (int| (int<< bits 6) v) (int+ n 6) acc)))))))
    (match
      ((eq? bytes (lit bad)) ())
      (#t
        (let go ((l bytes) (acc ()))
          (match
            ((null? l) (List reverse acc))
            ((null? (rest l)) ())
            (#t
              (let ((u (int| (int<< (first l) 8) (first (rest l)))) (r (rest (rest l))))
                (match
                  ((if (int< u 55296) #t (int< 56319 u)) (go r (List append (List reverse (utf8-encode u)) acc)))
                  ((if (null? r) #t (null? (rest r))) ())
                  (#t
                    (let ((lo (int| (int<< (first r) 8) (first (rest r)))))
                      (go (rest (rest r))
                          (List append (List reverse (utf8-encode (int+ 65536 (int| (int<< (int- u 55296) 10) (int- lo 56320))))) acc)))))))))))))

(def-class Utf7 ()
  (doc "IMAP's modified UTF-7 (RFC 3501 5.1.3), the form a mailbox name takes on the wire: printable ASCII as itself, \"&\" as \"&-\", anything else as base64 UTF-16 between \"&\" and \"-\"."
    (example "(Utf7 encode \"Entwürfe\")" "\"Entw&APw-rfe\"")
    (see encode decode))
  (static
    (method encode (self (param name STRING "A name, UTF-8"))
      (doc "The name in modified UTF-7."
        (returns STRING "Modified UTF-7")
        (example "(Utf7 encode \"Entwürfe\")" "\"Entw&APw-rfe\"")
        (example "(Utf7 encode \"R&D / 2026\")" "\"R&-D / 2026\""))
      (%encode name ()))

    (method encode-with (self (param name STRING "A name, UTF-8")
                              (param specials STRING "Printable bytes to write as base64 runs too"))
      (doc "The name in modified UTF-7, the bytes of specials written in base64 runs as well as the bytes outside printable ASCII. decode reads it back."
        (returns STRING "Modified UTF-7")
        (example "(Utf7 encode-with \"a.b/c\" \"./\")" "\"a&AC4-b&AC8-c\""))
      (%encode name (let go ((i (int- (str-byte-len specials) 1)) (acc ())) (if (int< i 0) acc (go (int- i 1) (pair (%byte specials i) acc))))))

    (method decode (self (param s STRING "Modified UTF-7"))
      (doc "The name as UTF-8. Text that is not modified UTF-7 (a run that is not base64 UTF-16, an \"&\" with no \"-\") is answered as it is written."
        (returns STRING "The name, UTF-8")
        (example "(Utf7 decode \"Entw&APw-rfe\")" "\"Entwürfe\"")
        (example "(Utf7 decode \"a&AC4-b\")" "\"a.b\"")
        (example "(Utf7 decode \"half&open\")" "\"half&open\""))
      (def n (str-byte-len s))
      (let go ((i 0) (acc ()))
        (match
          ((int= i n) (bytes->str (List reverse acc)))
          ((int= (%byte s i) 38)
            (let ((end (Str8 index-of "-" (str-byte-sub s i (int- n i)))))
              (match
                ((null? end) s)
                ((int= end 1) (go (int+ i 2) (pair 38 acc)))
                (#t (let ((run (%decode-run s (int+ i 1) (int+ i end))))
                      (if (null? run) s (go (int+ i (int+ end 1)) (List append (List reverse run) acc))))))))
          (#t (go (int+ i 1) (pair (%byte s i) acc))))))))

(doc (provide mail/utf7 Utf7)
  "IMAP's modified UTF-7 for mailbox names: encode, encode-with (more bytes kept out, as a Maildir store needs), and decode."
  (example "(Utf7 decode (Utf7 encode \"Entwürfe\"))" "\"Entwürfe\""))
