# Imap: the client and the server over a socket
# @weight 15
# @timeout-scale 4

The server runs in a child on a loopback port, over a Maildir store made for
the case; the client runs here. Under TLS the key is an RSA one openssl makes
for the run. A message's KEY is shown without its UIDVALIDITY, which comes
from the clock.

## the fixture

### a key for the run, and a server for each session

```x
(import mail/imap)
(import mail/maildir)
(import mail/message)
(import x/sys/socket)
(import x/sys/posix)
(import x/sys/proc)
(import x/sys/file)
(import x/net/tls13)
(def %iw-dir (Str8 append "/tmp/x-lib-mail-imap-" (%number->str (Sys getpid))))
(Proc run! (list "/bin/sh" "-c"
  (Str8 append "mkdir -p " %iw-dir " && cd " %iw-dir
    " && openssl req -x509 -newkey rsa:2048 -nodes -keyout rsa.key -out rsa.crt -days 1 -subj /CN=localhost >/dev/null 2>&1"
    " && cat rsa.key rsa.crt > rsa.pem")))
; the engines built once, before any child is forked
(Tls13 ready!)
(def %iw-pem (File read-all (Str8 append %iw-dir "/rsa.pem")))
; one session: the server in a child with OPTS over a fresh store, CLIENT here
; with the port; answers what CLIENT answered, or the error's label and text
(def %iw-one
  (fn (_ opts client)
    (def root (%spec-root))
    (Maildir create! root (list "INBOX"))
    (File write-all (Str8 append root "/cur/1.a.h:2,S") "From: ann@example.org\nSubject: one\n\nfirst\n")
    (File write-all (Str8 append root "/new/2.b.h") "From: bo@example.org\nSubject: two\n\nsecond\n")
    (def l (Socket tcp-listen-on "127.0.0.1" 0))
    (def port (Socket local-port l))
    (def pid (Sys fork))
    (when (= pid 0)
      (do (guard (e ())
            (let ((fd (Socket accept l)))
              (Socket close l)
              (Imap serve (Wire socket fd)
                (List append opts
                  (list (pair 'auth (fn (_ u p) (if (Str8 =? u "ann") (Str8 =? p "pw") #f)))
                        (pair 'store (fn (_ u) root)))))
              (Socket close fd)))
          (Sys exit 0)))
    (Socket close l)
    (def result (guard (e (list (Err label e) (Err text e))) (client port)))
    (Sys wait pid)
    (%spec-rm root)
    result))
; an entry's KEY without its UIDVALIDITY, and its INFO's subject alone
(def %iw-entry
  (fn (_ e)
    (def k (first e))
    (list (str-byte-sub k (int+ (Str8 index-of "." k) 1) (int- (str-byte-len k) (int+ (Str8 index-of "." k) 1)))
          (first (rest e)) (first (rest (rest e)))
          (rest (Assoc find 'subject (first (rest (rest (rest e)))))))))
(Str8 starts? "-----BEGIN" %iw-pem)
```
---
    #t

## in the clear

### login, folders, messages, read, flag!, create!, append, move!, search

```x
(%iw-one (list (list 'auth-in-clear))
  (fn (_ port)
    (def c (Imap connect "127.0.0.1" port))
    (Imap login c "ann" "pw")
    (def inbox (list "INBOX"))
    (def es (Imap messages c inbox))
    (def body (Message body (Message parse (Imap read c inbox (first es)))))
    (Imap flag! c inbox (first (rest es)) (list 'seen 'flagged))
    (Imap create! c (list "Sent"))
    (Imap append c (list "Sent") "Subject: three\n\nthird\n" (list 'seen))
    (Imap move! c inbox (first es) (list "Sent"))
    (def r (list (List map %iw-entry es) body
                 (Imap folders c)
                 (List map %iw-entry (Imap messages c inbox))
                 (List map %iw-entry (Imap messages c (list "Sent")))
                 (List length (Imap search c (list "Sent") "SUBJECT three"))))
    (Imap logout c)
    r))
```
---
    ((("1" #f ('seen) "one") ("2" #t () "two")) "first\r\n" (("INBOX") ("Sent")) (("2" #t ('flagged 'seen) "two")) (("1" #f ('seen) "three") ("2" #f ('seen) "one")) 1)

### LOGINDISABLED in the clear without 'auth-in-clear

```x
(%iw-one ()
  (fn (_ port)
    (def c (Imap connect "127.0.0.1" port))
    (def r (Imap capabilities c))
    (Imap logout c)
    r))
```
---
    ("IMAP4REV1" "LITERAL+" "SASL-IR" "UIDPLUS" "MOVE" "UNSELECT" "NAMESPACE" "LOGINDISABLED")

## STARTTLS

### STARTTLS, then LOGIN, which is offered only under it

```x
(%iw-one (list (pair 'pem %iw-pem))
  (fn (_ port)
    (def c (Imap connect "127.0.0.1" port))
    (def before (Imap capabilities c))
    (def after (Imap starttls c (list 'insecure)))
    (Imap login c "ann" "pw")
    (def r (list before after (Wire tls? (Imap wire c)) (List map %iw-entry (Imap messages c (list "INBOX")))))
    (Imap logout c)
    r))
```
---
    (("IMAP4REV1" "LITERAL+" "SASL-IR" "UIDPLUS" "MOVE" "UNSELECT" "NAMESPACE" "STARTTLS" "LOGINDISABLED") ("IMAP4REV1" "LITERAL+" "SASL-IR" "UIDPLUS" "MOVE" "UNSELECT" "NAMESPACE" "AUTH=PLAIN") #t (("1" #f ('seen) "one") ("2" #t () "two")))

## the end

### the key's directory removed

```x
(Proc run! (list "/bin/sh" "-c" (Str8 append "rm -rf " %iw-dir)))
(File exists? %iw-dir)
```
---
    #f
