# Smtp: the client and the server over a socket
# @weight 15
# @timeout-scale 4

The server runs in this process on a loopback port; the client runs in a
child. Under TLS the key is an RSA one openssl makes for the run, since x's
client checks RSA-PSS signatures. The report is what the server's deliver
function was given.

## the fixture

### a key for the run, and a server for each session

```x
(import mail/smtp)
(import x/sys/socket)
(import x/sys/posix)
(import x/sys/proc)
(import x/sys/file)
(import x/net/tls13)
(def %sw-dir (Str8 append "/tmp/x-lib-mail-smtp-" (%number->str (Sys getpid))))
(Proc run! (list "/bin/sh" "-c"
  (Str8 append "mkdir -p " %sw-dir " && cd " %sw-dir
    " && openssl req -x509 -newkey rsa:2048 -nodes -keyout rsa.key -out rsa.crt -days 1 -subj /CN=localhost >/dev/null 2>&1"
    " && cat rsa.key rsa.crt > rsa.pem")))
; the engines built once, before any child is forked
(Tls13 ready!)
(def %sw-pem (File read-all (Str8 append %sw-dir "/rsa.pem")))
; one session: CLIENT run in a child with the port; the server here with
; OPTS, its wire made by WIRE; answers what deliver was given
(def %sw-one
  (fn (_ wire opts client)
    (def l (Socket tcp-listen-on "127.0.0.1" 0))
    (def port (Socket local-port l))
    (def pid (Sys fork))
    (when (= pid 0)
      (do (Socket close l)
          (guard (e ()) (client port))
          (Sys exit 0)))
    (def fd (Socket accept l))
    (Socket close l)
    (def got (Vector make 1 0))
    (def result
      (guard (e (list (Err label e) (e msg)))
        (do (Smtp serve (wire (Wire socket fd))
              (List append opts
                (list (pair 'deliver (fn (_ from to text info)
                                       (obj-set! got 1 (list from to text (rest (Assoc find 'tls info)) (rest (Assoc find 'user info)))))))))
            (obj-ref got 1))))
    (Socket close fd)
    (Sys wait pid)
    result))
(def %sw-plain (fn (_ w) w))
(def %sw-check (fn (_ u p) (if (Str8 =? u "ann") (Str8 =? p "pw") #f)))
(Str8 starts? "-----BEGIN" %sw-pem)
```
---
    #t

## in the clear

### hello, a message to two recipients, quit

```x
(%sw-one %sw-plain ()
  (fn (_ port)
    (let ((s (Smtp connect "127.0.0.1" port)))
      (do (Smtp hello s "client.test")
          (Smtp send s "a@x" (list "b@y" "c@z") "Subject: hi\n\n.leading dot\nend\n")
          (Smtp quit s)))))
```
---
    ("a@x" ("b@y" "c@z") "Subject: hi\r\n\r\n.leading dot\r\nend\r\n" #f ())

## STARTTLS

### STARTTLS, then AUTH, which is offered only under it, then the message

```x
(%sw-one %sw-plain (list (pair 'pem %sw-pem) (pair 'auth %sw-check) (list 'require-auth))
  (fn (_ port)
    (let ((s (Smtp connect "127.0.0.1" port)))
      (do (Smtp hello s "client.test")
          (unless (null? (Smtp extension s "AUTH")) (Sys exit 3))
          (Smtp starttls s (list 'insecure))
          (Smtp auth s "ann" "pw")
          (Smtp send s "ann@x" (list "b@y") "Subject: secret\n\nunder tls\n")
          (Smtp quit s)))))
```
---
    ("ann@x" ("b@y") "Subject: secret\r\n\r\nunder tls\r\n" #t "ann")

### TLS from the start, as on port 465

```x
(%sw-one (fn (_ w) (Wire tls-accept w %sw-pem)) ()
  (fn (_ port)
    (let ((s (Smtp connect "127.0.0.1" port (list 'tls) (list 'insecure))))
      (do (Smtp hello s "client.test")
          (Smtp send s "a@x" (list "b@y") "x\n")
          (Smtp quit s)))))
```
---
    ("a@x" ("b@y") "x\r\n" #t ())

## the end

### the key's directory removed

```x
(Proc run! (list "/bin/sh" "-c" (Str8 append "rm -rf " %sw-dir)))
(File exists? %sw-dir)
```
---
    #f
