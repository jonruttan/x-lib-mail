# Message: an Internet message, its header and body
# @weight 1

A message is (FIELDS . BODY): the (NAME . VALUE) fields in order and the text
after the blank line (RFC 5322).

## parse

### fields and body, CRLF line ends

```x
(import mail/message)
(Message parse "From: a@b.org\r\nTo: c@d.org\r\nSubject: hi\r\n\r\nline one\r\nline two\r\n")
```
---
    ((("From" . "a@b.org") ("To" . "c@d.org") ("Subject" . "hi")) . "line one\r\nline two\r\n")

### LF alone ends a line too

```x
(import mail/message)
(Message fields (Message parse "A: 1\nB: 2\n\nbody"))
```
---
    (("A" . "1") ("B" . "2"))

### a continuation line joins the field before it, its space kept

```x
(import mail/message)
(Message field (Message parse "Subject: a long\r\n\tsubject\r\n  here\r\n\r\n") "subject")
```
---
    "a long\tsubject  here"

### the space after the colon and at the end of a value is taken off; none is needed

```x
(import mail/message)
(Message fields (Message parse "A:   x  \nB:y\nC:\n\n"))
```
---
    (("A" . "x") ("B" . "y") ("C" . ""))

### text with no blank line is all header

```x
(import mail/message)
(Message parse "A: 1\r\nB: 2")
```
---
    ((("A" . "1") ("B" . "2")) . "")

### a header line with no colon is refused

```x
(import mail/message)
(guard (e (e msg)) (Message parse "A: 1\nnonsense\n\nbody"))
```
---
    "Message: a header line with no colon"

### the header cannot start with a continuation line

```x
(import mail/message)
(guard (e (e msg)) (Message parse " A: 1\n\n"))
```
---
    "Message: the header starts with a continuation line"

## fields

### a name is looked up in any case; a missing one is nil

```x
(import mail/message)
(def m (Message parse "Content-Type: text/plain\n\n"))
(list (Message field m "content-type") (Message field m "CONTENT-TYPE") (Message field m "To"))
```
---
    ("text/plain" "text/plain" ())

### every value of a repeated field, in order

```x
(import mail/message)
(Message values (Message parse "Received: one\nTo: x\nreceived: two\n\n") "Received")
```
---
    ("one" "two")

### add, set and remove

```x
(import mail/message)
(def m (Message parse "A: 1\nB: 2\na: 3\n\nbody"))
(list (Message fields (Message add m "C" "4"))
      (Message fields (Message set m "a" "9"))
      (Message fields (Message set m "D" "5"))
      (Message fields (Message remove m "a")))
```
---
    ((("A" . "1") ("B" . "2") ("a" . "3") ("C" . "4")) (("A" . "9") ("B" . "2")) (("A" . "1") ("B" . "2") ("a" . "3") ("D" . "5")) (("B" . "2")))

## write

### header lines end with CRLF, then a blank line and the body

```x
(import mail/message)
(Str8 replace "\r\n" "|" (Message write (Message make (list (pair "From" "a@b") (pair "To" "c@d")) "hi\r\n")))
```
---
    "From: a@b|To: c@d||hi|"

### a long value is folded before a space, each line at most 78 bytes

```x
(import mail/message)
(def v "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen")
(def text (Message write (Message make (list (pair "Subject" v)) "")))
(list (List map (fn (_ l) (Str8 length l)) (Str8 split "\r\n" text))
      (Str8 =? v (Message field (Message parse text) "Subject")))
```
---
    ((71 34 0 0) #t)

### a word longer than a line stays whole

```x
(import mail/message)
(def v (Str8 repeat 100 "x"))
(Str8 length (first (Str8 split "\r\n" (Message write (Message make (list (pair "X" v)) "")))))
```
---
    103

### written and parsed again, a message is the same

```x
(import mail/message)
(def m (Message parse "From: Ann <ann@a.org>\r\nSubject: =?utf-8?B?Y2Fmw6k=?=\r\n\r\nhello\r\n"))
(equal? m (Message parse (Message write m)))
```
---
    #t

## encoded words

### B and Q words decoded; the space between two words dropped, other text kept

```x
(import mail/message)
(list (Message decode-words "=?utf-8?B?Y2Fmw6k=?= au lait")
      (Message decode-words "=?ISO-8859-1?q?a_b?=  =?utf-8?Q?=63=64?= end")
      (Message decode-words "plain text"))
```
---
    ("café au lait" "a bcd end" "plain text")

### a word that does not decode is left as it is

```x
(import mail/message)
(list (Message decode-words "=?utf-8?X?abc?=") (Message decode-words "=?utf-8?Q?=zz?=") (Message decode-words "a =? b"))
```
---
    ("=?utf-8?X?abc?=" "=?utf-8?Q?=zz?=" "a =? b")

### printable ASCII is not encoded; other text becomes UTF-8 B words

```x
(import mail/message)
(list (Message encode-words "plain") (Message encode-words "café"))
```
---
    ("plain" "=?utf-8?B?Y2Fmw6k=?=")

### long text becomes several words, none cutting a UTF-8 sequence, and decodes back

```x
(import mail/message)
(def t (Str8 repeat 40 "é"))
(def e (Message encode-words t))
(list (List all? (fn (_ w) (<= (Str8 length w) 75)) (Str8 split " " e))
      (List length (Str8 split " " e))
      (Str8 =? t (Message decode-words e)))
```
---
    (#t 2 #t)

## addresses

### display names, quoted commas, bare addresses

```x
(import mail/message)
(Message addresses "Ann <ann@a.org>, \"Bo, Jr\" <bo@b.org>, cy@c.org")
```
---
    (("Ann" . "ann@a.org") ("Bo, Jr" . "bo@b.org") ("" . "cy@c.org"))

### a group's name dropped, comments taken out, empties skipped

```x
(import mail/message)
(list (Message addresses "team: a@x, b@y;")
      (Message addresses "dee@d.org (Dee D), , Eve (the boss) <eve@e.org>"))
```
---
    ((("" . "a@x") ("" . "b@y")) (("" . "dee@d.org") ("Eve" . "eve@e.org")))
