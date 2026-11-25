# Mime: MIME bodies on messages
# @weight 1

Content-Type and its parameters, bodies decoded from base64 and
quoted-printable, and multipart bodies split and built (RFC 2045, 2046).

## content type

### the type in lower case, parameters named in lower case, quoted values unquoted

```x
(import mail/mime)
(Mime content-type "Multipart/Mixed; Boundary=\"a;b\"; x = 1 ; title=\"say \\\"hi\\\"\"")
```
---
    ("multipart/mixed" ("boundary" . "a;b") ("x" . "1") ("title" . "say \"hi\""))

### a message's type, parameter and encoding, with their defaults

```x
(import mail/mime)
(def m (Message parse "Content-Type: TEXT/html; charset=\"UTF-8\"\nContent-Transfer-Encoding: Quoted-Printable\n\n"))
(def bare (Message parse "A: 1\n\n"))
(list (Mime type m) (Mime param m "Charset") (Mime encoding m)
      (Mime type bare) (Mime param bare "charset") (Mime encoding bare))
```
---
    ("text/html" "UTF-8" "quoted-printable" "text/plain" () "7bit")

### a file name from Content-Disposition, else Content-Type's name, decoded

```x
(import mail/mime)
(list (Mime filename (Message parse "Content-Type: a/b; name=n.txt\nContent-Disposition: attachment; filename=\"f.txt\"\n\n"))
      (Mime filename (Message parse "Content-Type: a/b; name=\"=?utf-8?B?Y2Fmw6kudHh0?=\"\n\n"))
      (Mime filename (Message parse "Content-Type: a/b\n\n")))
```
---
    ("f.txt" "café.txt" ())

## decoding

### base64, with its line breaks, and NULs kept in the region

```x
(import mail/mime)
(def m (Message parse "Content-Transfer-Encoding: base64\r\n\r\naGVs\r\nbG8=\r\n"))
(list (Mime decode m)
      (Bytes hex (Mime decode-region (Message parse "Content-Transfer-Encoding: base64\n\nAGEA\n"))))
```
---
    ("hello" "006100")

### quoted-printable: =XX, soft breaks, trailing spaces dropped, a stray = kept

```x
(import mail/mime)
(Mime decode (Message parse "Content-Transfer-Encoding: quoted-printable\n\ncaf=C3=A9 =\nau lait  \r\nx=3Dy =zz=\r\nend"))
```
---
    "café au lait\r\nx=y =zzend"

### 7bit and 8bit bodies are as they are; an unknown encoding is refused

```x
(import mail/mime)
(list (Mime decode (Message parse "Content-Transfer-Encoding: 8bit\n\ncafé"))
      (guard (e (e msg)) (Mime decode (Message parse "Content-Transfer-Encoding: x-uue\n\nx"))))
```
---
    ("café" "Mime: an unknown transfer encoding")

## encoding

### quoted-printable: = and other bytes as =XX, a space before a line end encoded

```x
(import mail/mime)
(Mime quoted-printable "café = 1 \nnext\ttab\t\r\nlast")
```
---
    "caf=C3=A9 =3D 1=20\r\nnext\ttab=09\r\nlast"

### a long line is broken with soft breaks at 76, and decodes back

```x
(import mail/mime)
(def t (Str8 repeat 50 "ab"))
(def q (Mime quoted-printable t))
(list (List map (fn (_ l) (Str8 length l)) (Str8 split "\r\n" q))
      (Str8 =? t (Mime decode (Message parse (Str8 append "Content-Transfer-Encoding: quoted-printable\n\n" q)))))
```
---
    ((76 25) #t)

### a text part is 7bit when it can be, else quoted-printable

```x
(import mail/mime)
(list (Mime encoding (Mime text "hello\nthere"))
      (Mime encoding (Mime text "café"))
      (Mime decode (Mime text "café")))
```
---
    ("7bit" "quoted-printable" "café")

### an attachment is base64 in lines of 76, its name in both fields

```x
(import mail/mime)
(def a (Mime attachment "report.bin" "application/octet-stream" (Bytes of-hex (Str8 repeat 60 "00ff"))))
(list (Message field a "Content-Type") (Message field a "Content-Disposition")
      (List map (fn (_ l) (Str8 length l)) (Str8 split "\r\n" (Message body a)))
      (Bytes hex (Bytes sub (Mime decode-region a) 0 4)) (Bytes length (Mime decode-region a)))
```
---
    ("application/octet-stream; name=\"report.bin\"" "attachment; filename=\"report.bin\"" (76 76 8 0) "00ff00ff" 120)

## multipart

### parts split at the boundary lines; preamble and epilogue dropped

```x
(import mail/mime)
(def m (Message parse "Content-Type: multipart/mixed; boundary=\"XX\"\r\n\r\npreamble\r\n--XX\r\nContent-Type: text/plain\r\n\r\none\r\n--XX  \r\n\r\ntwo\r\nlines\r\n--XX--\r\nepilogue\r\n"))
(List map (fn (_ p) (list (Mime type p) (Message body p))) (Mime parts m))
```
---
    (("text/plain" "one") ("text/plain" "two\r\nlines"))

### a boundary must start a line; text that only holds it is body

```x
(import mail/mime)
(def m (Message parse "Content-Type: multipart/mixed; boundary=b\n\n--b\n\nsee --b here\n--bx\n--b--\n"))
(List map (fn (_ p) (Message body p)) (Mime parts m))
```
---
    ("see --b here\n--bx")

### a multipart with no closing line ends at the body's end

```x
(import mail/mime)
(List map (fn (_ p) (Message body p)) (Mime parts (Message parse "Content-Type: multipart/mixed; boundary=b\n\n--b\n\none\n--b\n\ntwo\n")))
```
---
    ("one" "two\n")

### not a multipart, or no boundary, is refused

```x
(import mail/mime)
(list (guard (e (e msg)) (Mime parts (Message parse "Content-Type: text/plain\n\nx")))
      (guard (e (e msg)) (Mime parts (Message parse "Content-Type: multipart/mixed\n\nx"))))
```
---
    ("Mime: not a multipart" "Mime: a multipart with no boundary")

### built, written and parsed back: the same parts

```x
(import mail/mime)
(def m (Message add (Mime multipart "mixed" (list (Mime text "hello") (Mime attachment "a.bin" "application/octet-stream" (Bytes of-hex "00010203")))) "Subject" "test"))
(def back (Message parse (Message write m)))
(def ps (Mime parts back))
(list (Message field back "MIME-Version") (Mime type back) (Message field back "Subject")
      (Mime decode (first ps)) (Mime filename (first (rest ps))) (Bytes hex (Mime decode-region (first (rest ps)))))
```
---
    ("1.0" "multipart/mixed" "test" "hello" "a.bin" "00010203")

### nested: a part that is itself a multipart

```x
(import mail/mime)
(def inner (Mime multipart "alternative" (list (Mime text "plain") (Mime text "also"))))
(def outer (Message parse (Message write (Mime multipart "mixed" (list inner (Mime text "after"))))))
(def ps (Mime parts outer))
(list (Mime type (first ps)) (List map (fn (_ p) (Mime decode p)) (Mime parts (first ps))) (Mime decode (first (rest ps))))
```
---
    ("multipart/alternative" ("plain" "also") "after")
