# Smtp: client and server on a script wire
# @weight 1

Each side runs against a script: the text the other side sends, all of it,
and a record of what was written back. No network.

## the server

### greeting, EHLO's extensions, QUIT

```x
(import mail/smtp)
(Str8 split "\r\n" (Wire output (Smtp serve (Wire script "EHLO client.example\r\nQUIT\r\n") (list (pair 'name "mx.example")))))
```
---
    ("220 mx.example ESMTP" "250-mx.example hello client.example" "250-PIPELINING" "250-SIZE 10485760" "250 8BITMIME" "221 2.0.0 Bye" "")

### a message delivered: sender, recipients in order, dots taken off, CRLF line ends

```x
(import mail/smtp)
(def got (Vector make 1 0))
(def w (Wire script "HELO c\r\nMAIL FROM:<a@x>\r\nRCPT TO:<b@y>\r\nRCPT TO:<c@z>\r\nDATA\r\nSubject: hi\r\n\r\n..dot\r\nbare lf\n.\r\nQUIT\r\n"))
(Smtp serve w (list (pair 'deliver (fn (_ from to text info) (obj-set! got 1 (list from to text (rest (Assoc find 'hello info))))))))
(list (obj-ref got 1) (Str8 split "\r\n" (Wire output w)))
```
---
    (("a@x" ("b@y" "c@z") "Subject: hi\r\n\r\n.dot\r\nbare lf\r\n" "c") ("220 localhost ESMTP" "250 localhost" "250 2.1.0 OK" "250 2.1.5 OK" "250 2.1.5 OK" "354 End data with <CR><LF>.<CR><LF>" "250 2.0.0 OK" "221 2.0.0 Bye" ""))

### commands out of order are refused, and the session goes on

```x
(import mail/smtp)
(def w (Wire script "MAIL FROM:<a@x>\r\nHELO c\r\nRCPT TO:<b@y>\r\nDATA\r\nMAIL FROM:<a@x>\r\nMAIL FROM:<a@x>\r\nDATA\r\nRSET\r\nRCPT TO:<b@y>\r\nQUIT\r\n"))
(List map (fn (_ l) (if (int< 2 (Str8 length l)) (Str8 sub 0 3 l) l)) (Str8 split "\r\n" (Wire output (Smtp serve w ()))))
```
---
    ("220" "503" "250" "503" "503" "250" "503" "503" "250" "503" "221" "")

### bad syntax, unknown commands, NOOP, VRFY and an empty HELO

```x
(import mail/smtp)
(def w (Wire script "HELO\r\nHELO c\r\nMAIL a@x\r\nMAIL FROM:<a@x>\r\nRCPT b@y\r\nWHAT\r\nnoop\r\nVRFY b\r\nquit\r\n"))
(List map (fn (_ l) (if (int< 2 (Str8 length l)) (Str8 sub 0 3 l) l)) (Str8 split "\r\n" (Wire output (Smtp serve w ()))))
```
---
    ("220" "501" "250" "501" "250" "501" "500" "250" "252" "221" "")

### the rcpt function decides; a deliver that raises answers 451

```x
(import mail/smtp)
(def w (Wire script "HELO c\r\nMAIL FROM:<>\r\nRCPT TO:<no@y>\r\nRCPT TO:<yes@y>\r\nDATA\r\nx\r\n.\r\nQUIT\r\n"))
(Smtp serve w (list (pair 'rcpt (fn (_ a u) (Str8 starts? "yes" a))) (pair 'deliver (fn (_ f t x i) (Err raise 'io "disk full" ())))))
(List map (fn (_ l) (if (int< 2 (Str8 length l)) (Str8 sub 0 3 l) l)) (Str8 split "\r\n" (Wire output w)))
```
---
    ("220" "250" "250" "550" "250" "354" "451" "221" "")

### SIZE: a declared size over the limit is refused, and so is a message that runs over

```x
(import mail/smtp)
(def n (Vector make 1 0))
(def w (Wire script "EHLO c\r\nMAIL FROM:<a@x> SIZE=500\r\nMAIL FROM:<a@x> SIZE=20\r\nRCPT TO:<b@y>\r\nDATA\r\n0123456789\r\n0123456789\r\n0123456789\r\n.\r\nQUIT\r\n"))
(Smtp serve w (list (pair 'size 30) (pair 'deliver (fn (_ f t x i) (obj-set! n 1 1)))))
(list (obj-ref n 1) (List map (fn (_ l) (if (int< 2 (Str8 length l)) (Str8 sub 0 3 l) l)) (List drop 5 (Str8 split "\r\n" (Wire output w)))))
```
---
    (0 ("552" "250" "250" "354" "552" "221" ""))

### AUTH is offered only under TLS, unless allowed in the clear

```x
(import mail/smtp)
(def check (fn (_ u p) #t))
(def ehlo (fn (_ opts) (Str8 split "\r\n" (Wire output (Smtp serve (Wire script "EHLO c\r\nAUTH PLAIN AGEAYg==\r\nQUIT\r\n") opts)))))
(list (ehlo (list (pair 'auth check)))
      (ehlo (list (pair 'auth check) (list 'auth-in-clear))))
```
---
    (("220 localhost ESMTP" "250-localhost hello c" "250-PIPELINING" "250-SIZE 10485760" "250 8BITMIME" "503 5.5.1 AUTH not offered" "221 2.0.0 Bye" "") ("220 localhost ESMTP" "250-localhost hello c" "250-PIPELINING" "250-SIZE 10485760" "250-8BITMIME" "250 AUTH PLAIN LOGIN" "235 2.7.0 Authentication successful" "221 2.0.0 Bye" ""))

### AUTH PLAIN and LOGIN, right and wrong; the user reaches rcpt and deliver

```x
(import mail/smtp)
(def seen (Vector make 1 0))
(def opts (list (list 'auth-in-clear) (list 'require-auth)
                (pair 'auth (fn (_ u p) (if (Str8 =? u "ann") (Str8 =? p "pw") #f)))
                (pair 'deliver (fn (_ f t x info) (obj-set! seen 1 (rest (Assoc find 'user info)))))))
; AGFubgB3cm9uZw== is NUL ann NUL wrong; YW5u is ann, cHc= is pw
(def w (Wire script "EHLO c\r\nMAIL FROM:<a@x>\r\nAUTH PLAIN AGFubgB3cm9uZw==\r\nAUTH LOGIN\r\nYW5u\r\ncHc=\r\nAUTH PLAIN\r\nMAIL FROM:<a@x>\r\nRCPT TO:<b@y>\r\nDATA\r\nx\r\n.\r\nQUIT\r\n"))
(Smtp serve w opts)
(list (obj-ref seen 1) (List map (fn (_ l) (if (int< 2 (Str8 length l)) (Str8 sub 0 3 l) l)) (List drop 6 (Str8 split "\r\n" (Wire output w)))))
```
---
    ("ann" ("530" "535" "334" "334" "235" "503" "250" "250" "354" "250" "221" ""))

### STARTTLS on a script is refused when no key is given

```x
(import mail/smtp)
(List drop 1 (Str8 split "\r\n" (Wire output (Smtp serve (Wire script "EHLO c\r\nSTARTTLS\r\nQUIT\r\n") ()))))
```
---
    ("250-localhost hello c" "250-PIPELINING" "250-SIZE 10485760" "250 8BITMIME" "502 5.5.1 STARTTLS not offered" "221 2.0.0 Bye" "")

### the wire's end without QUIT ends the session

```x
(import mail/smtp)
(Wire output (Smtp serve (Wire script "HELO c\r\n") ()))
```
---
    "220 localhost ESMTP\r\n250 localhost\r\n"

## the client

### hello: EHLO's extensions, in upper case, with their parameters

```x
(import mail/smtp)
(def s (Smtp client (Wire script "220 mx ESMTP\r\n250-mx hello\r\n250-size 1000\r\n250-AUTH PLAIN LOGIN\r\n250 8BITMIME\r\n")))
(list (Smtp hello s "me") (Smtp extension s "auth") (Smtp extension s "STARTTLS") (Wire output (Smtp wire s)))
```
---
    ((("SIZE" "1000") ("AUTH" "PLAIN" "LOGIN") ("8BITMIME")) ("PLAIN" "LOGIN") () "EHLO me\r\n")

### HELO where EHLO is refused

```x
(import mail/smtp)
(def s (Smtp client (Wire script "220 old\r\n500 what\r\n250 old\r\n")))
(list (Smtp hello s "me") (Wire output (Smtp wire s)))
```
---
    (() "EHLO me\r\nHELO me\r\n")

### a greeting that is not 220 is refused

```x
(import mail/smtp)
(guard (e (list (Err label e) (e msg) (e data))) (Smtp client (Wire script "554 go away\r\n")))
```
---
    ('io "Smtp: the greeting: 554 go away" (554 "go away"))

### send: the commands, the text dot-stuffed with CRLF, a refused recipient answered

```x
(import mail/smtp)
(def s (Smtp client (Wire script "220 mx\r\n250 ok\r\n250 ok\r\n550 no such user\r\n354 go\r\n250 queued\r\n")))
(list (Smtp send s "a@x" (list "b@y" "c@z") "Subject: hi\n\n.dot\nend")
      (Str8 split "\r\n" (Wire output (Smtp wire s))))
```
---
    ((("c@z" 550 "no such user")) ("MAIL FROM:<a@x>" "RCPT TO:<b@y>" "RCPT TO:<c@z>" "DATA" "Subject: hi" "" "..dot" "end" "." ""))

### send takes a message too

```x
(import mail/smtp)
(def s (Smtp client (Wire script "220 mx\r\n250 ok\r\n250 ok\r\n354 go\r\n250 queued\r\n")))
(Smtp send s "a@x" (list "b@y") (Message make (list (pair "Subject" "hi")) "body\r\n"))
(List drop 3 (Str8 split "\r\n" (Wire output (Smtp wire s))))
```
---
    ("Subject: hi" "" "body" "." "")

### every recipient refused: RSET, and a raise

```x
(import mail/smtp)
(def s (Smtp client (Wire script "220 mx\r\n250 ok\r\n550 no\r\n250 reset\r\n")))
(list (guard (e (e msg)) (Smtp send s "a@x" (list "b@y") "x"))
      (Str8 split "\r\n" (Wire output (Smtp wire s))))
```
---
    ("Smtp: the server took no recipient" ("MAIL FROM:<a@x>" "RCPT TO:<b@y>" "RSET" ""))

### a multi-line reply is one reply

```x
(import mail/smtp)
(Smtp command (Smtp client (Wire script "220 mx\r\n214-one\r\n214-two\r\n214 three\r\n")) "HELP")
```
---
    (214 "one" "two" "three")

### AUTH LOGIN where PLAIN is not named; refused credentials raise

```x
(import mail/smtp)
(def s (Smtp client (Wire script "220 mx\r\n250-mx\r\n250 AUTH LOGIN\r\n334 VXNlcm5hbWU6\r\n334 UGFzc3dvcmQ6\r\n235 ok\r\n")))
(Smtp hello s "me")
(def t (Smtp client (Wire script "220 mx\r\n535 bad\r\n")))
(list (Smtp auth s "ann" "pw") (List drop 1 (Str8 split "\r\n" (Wire output (Smtp wire s))))
      (guard (e (e msg)) (Smtp auth t "ann" "wrong")))
```
---
    (#t ("AUTH LOGIN" "YW5u" "cHc=" "") "Smtp: AUTH PLAIN: 535 bad")

### the client and the server on one script each, the server's output the client's input

```x
(import mail/smtp)
(def got (Vector make 1 0))
(def server (Smtp serve (Wire script "EHLO me\r\nMAIL FROM:<a@x>\r\nRCPT TO:<b@y>\r\nDATA\r\nSubject: s\r\n\r\n..x\r\n.\r\nQUIT\r\n")
                        (list (pair 'deliver (fn (_ f t x i) (obj-set! got 1 x))))))
(def c (Smtp client (Wire script (Wire output server))))
(Smtp hello c "me")
(Smtp send c "a@x" (list "b@y") "Subject: s\n\n.x\n")
(Smtp quit c)
(list (obj-ref got 1) (Str8 =? (Wire output (Smtp wire c)) "EHLO me\r\nMAIL FROM:<a@x>\r\nRCPT TO:<b@y>\r\nDATA\r\nSubject: s\r\n\r\n..x\r\n.\r\nQUIT\r\n"))
```
---
    ("Subject: s\r\n\r\n.x\r\n" #t)
