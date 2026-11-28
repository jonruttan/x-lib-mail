# Maildir: a Maildir++ mail store
# @weight 1

Folders named by lists of names, one file a message, each message an entry
(KEY NEW? FLAGS) with its flags in its file name.

## folders

### create! makes a folder's directories and marks a dot folder

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(def r (list (Maildir create! root (list "Sent")) (%spec-tree root)))
(%spec-rm root)
r
```
---
    (("Sent") (".Sent/" ".Sent/cur/" ".Sent/maildirfolder" ".Sent/new/" ".Sent/tmp/" "cur/" "new/" "tmp/"))

### create! leaves a folder that is there as it is

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(def e (Maildir deliver root (list "INBOX") "A: 1\n\nhi"))
(Maildir create! root (list "INBOX"))
(def r (List length (Maildir messages root (list "INBOX"))))
(%spec-rm root)
r
```
---
    1

### folders lists INBOX first, then the dot folders in directory order

```x
(import mail/maildir)
(def root (%spec-root))
(List for-each (fn (_ f) (Maildir create! root f))
  (list (list "Sent") (list "INBOX") (list "Lists" "x-lang") (list "Drafts")))
(File mkdir (Str8 append root "/.NotAFolder"))
(def r (Maildir folders root))
(%spec-rm root)
r
```
---
    (("INBOX") ("Drafts") ("Lists" "x-lang") ("Sent"))

### a name outside printable ASCII, or with a dot or slash, is written in modified UTF-7

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "Entwürfe"))
(Maildir create! root (list "Lists" "x.lang/b&c"))
(def r (list (File list-dir root) (Maildir folders root)))
(%spec-rm root)
(list (List sort (fn (_ a b) (Str8 <? a b)) (first r)) (first (rest r)))
```
---
    ((".Entw&APw-rfe" ".Lists.x&AC4-lang&AC8-b&-c") (("Entwürfe") ("Lists" "x.lang/b&c")))

### a name of any case INBOX is the root

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "inbox"))
(def r (%spec-tree root))
(%spec-rm root)
r
```
---
    ("cur/" "new/" "tmp/")

### a folder that is not a list of names is refused

```x
(import mail/maildir)
(list (guard (e (e msg)) (Maildir create! "/tmp" (list "Lists" "")))
      (guard (e (e msg)) (Maildir create! "/tmp" ())))
```
---
    ("Maildir: a folder is a list of names, none empty" "Maildir: a folder is a list of names, none empty")

## messages

### deliver puts a message in new/, read gives it back

```x
(import mail/maildir)
(import mail/message)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(def e (Maildir deliver root (list "INBOX") "From: a@b.org\r\n\r\nhello\r\n"))
(def r (list (first (rest e)) (Maildir flags e)
             (equal? (List map (fn (_ x) (List init x)) (Maildir messages root (list "INBOX"))) (list e))
             (Message parse (Maildir read root (list "INBOX") e))
             (Str8 index-of "/" (first e)) (Str8 index-of ":" (first e))))
(%spec-rm root)
r
```
---
    (#t () #t ((("From" . "a@b.org")) . "hello\r\n") () ())

### deliver with flags puts the message in cur/

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "Sent"))
(def e (Maildir deliver root (list "Sent") "A: 1\n\nsent" (list (lit seen))))
(def r (list (rest e) (List map (fn (_ n) (Str8 sub (Str8 index-of ":" n) 4 n))
                                (File list-dir (Str8 append root "/.Sent/cur")))
             (File list-dir (Str8 append root "/.Sent/tmp"))))
(%spec-rm root)
r
```
---
    ((#f ('seen)) (":2,S") ())

### messages reads new/ and cur/ in key order and leaves out dot files

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(File write-all (Str8 append root "/cur/200.a.h:2,SR") "A: 1\n\n")
(File write-all (Str8 append root "/new/300.b.h") "A: 1\n\n")
(File write-all (Str8 append root "/cur/100.c.h:2,") "A: 1\n\n")
(File write-all (Str8 append root "/cur/.hidden") "")
(def r (List map (fn (_ x) (List init x)) (Maildir messages root (list "INBOX"))))
(%spec-rm root)
r
```
---
    (("100.c.h" #f ()) ("200.a.h" #f ('replied 'seen)) ("300.b.h" #t ()))

### flags reads an entry's flags in their order

```x
(import mail/maildir)
(Maildir flags (list "k" #f (list (lit trashed) (lit draft) (lit seen))))
```
---
    ('draft 'seen 'trashed)

## flag!

### flag! moves a new message to cur/ with its letters in order

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(File write-all (Str8 append root "/new/1.x.h") "A: 1\n\n")
(def e (first (Maildir messages root (list "INBOX"))))
(def f (Maildir flag! root (list "INBOX") e (list (lit seen) (lit flagged) (lit seen))))
(def r (list (List init f) (%spec-tree root)))
(%spec-rm root)
r
```
---
    (("1.x.h" #f ('flagged 'seen)) ("cur/" "cur/1.x.h:2,FS" "new/" "tmp/"))

### letters with no flag symbol stay on the file

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(File write-all (Str8 append root "/cur/1.x.h:2,Sab") "A: 1\n\n")
(def e (first (Maildir messages root (list "INBOX"))))
(def f (Maildir flag! root (list "INBOX") e (list (lit replied))))
(def r (list (List init e) (List init f) (File list-dir (Str8 append root "/cur"))))
(%spec-rm root)
r
```
---
    (("1.x.h" #f ('seen)) ("1.x.h" #f ('replied)) ("1.x.h:2,Rab"))

### a message renamed since its entry was read is found by its key

```x
(import mail/maildir)
(import mail/message)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(File write-all (Str8 append root "/new/1.x.h") "A: 1\n\nbody")
(def e (first (Maildir messages root (list "INBOX"))))
(File rename (Str8 append root "/new/1.x.h") (Str8 append root "/cur/1.x.h:2,T"))
(def r (list (rest (Message parse (Maildir read root (list "INBOX") e)))
             (List init (Maildir flag! root (list "INBOX") e (list (lit seen) (lit trashed))))))
(%spec-rm root)
r
```
---
    ("body" ("1.x.h" #f ('seen 'trashed)))

### a flag with no letter is refused; a key not in the folder is too

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(def e (Maildir deliver root (list "INBOX") "A: 1\n\n"))
(def r (list (guard (x (x msg)) (Maildir flag! root (list "INBOX") e (list (lit junk))))
             (guard (x (x msg)) (Maildir read root (list "INBOX") (list "gone" #t ())))))
(%spec-rm root)
r
```
---
    ("Maildir: no such flag" "Maildir: no message of that key")

## move!

### move! takes a message to another folder, its name as it is

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(Maildir create! root (list "Trash"))
(File write-all (Str8 append root "/cur/1.x.h:2,S") "A: 1\n\n")
(def e (first (Maildir messages root (list "INBOX"))))
(def m (Maildir move! root (list "INBOX") e (list "Trash")))
(def bare (fn (_ l) (List map (fn (_ x) (List init x)) l)))
(def r (list (List init m) (bare (Maildir messages root (list "INBOX"))) (bare (Maildir messages root (list "Trash")))))
(%spec-rm root)
r
```
---
    (("1.x.h" #f ('seen)) () (("1.x.h" #f ('seen))))

## INFO

### messages reads INFO from the header alone: fields as they stand, the file's time and size

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(def text "Date: Mon, 23 Nov 2026 10:00:00 +0000\r\nFrom: Ann B <ann@example.org>\r\nTo: me@example.org\r\nSubject: two\r\n words\r\nMessage-ID: <2@x>\r\nIn-Reply-To: <1@x>\r\n\r\nCc: not a field\r\n")
(File write-all (Str8 append root "/cur/1.x.h:2,S") text)
(def info (first (rest (rest (rest (first (Maildir messages root (list "INBOX"))))))))
(def d (rest (Assoc find 'internal-date info)))
(def r (list (List init (List init info)) (rest (Assoc find 'size info))
             (Str8 length d) (Str8 ends? " +0000" d) (Str8 sub 2 1 d) (Str8 sub 6 1 d)))
(%spec-rm root)
r
```
---
    ((('date . "Mon, 23 Nov 2026 10:00:00 +0000") ('from . "Ann B <ann@example.org>") ('to . "me@example.org") ('cc) ('subject . "two words") ('message-id . "<2@x>") ('in-reply-to . "<1@x>")) 170 26 #t "-" "-")

### a header Message parse refuses gives nil fields, not a failed listing

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(File write-all (Str8 append root "/new/1.x.h") "not a header line\n\nbody\n")
(def info (first (rest (rest (rest (first (Maildir messages root (list "INBOX"))))))))
(def r (list (rest (Assoc find 'subject info)) (rest (Assoc find 'from info)) (rest (Assoc find 'size info))))
(%spec-rm root)
r
```
---
    (() () 24)

### flag! and move! keep the entry's INFO

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(Maildir create! root (list "Trash"))
(File write-all (Str8 append root "/new/1.x.h") "Subject: hi\n\n")
(def e (first (Maildir messages root (list "INBOX"))))
(def f (Maildir flag! root (list "INBOX") e (list (lit seen))))
(def m (Maildir move! root (list "INBOX") f (list "Trash")))
(def r (list (equal? (List last f) (List last e)) (equal? (List last m) (List last e)) (List length m)))
(%spec-rm root)
r
```
---
    (#t #t 4)

## entries, delete!, uids!

### entries lists without INFO; delete! removes a file found by its key

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(File write-all (Str8 append root "/new/2.b.h") "A: 1\n\n")
(File write-all (Str8 append root "/cur/1.a.h:2,ST") "A: 1\n\n")
(def es (Maildir entries root (list "INBOX")))
(Maildir delete! root (list "INBOX") (first es))
(def r (list es (%spec-tree root) (guard (x (Err label x)) (Maildir delete! root (list "INBOX") (first es)))))
(%spec-rm root)
r
```
---
    ((("1.a.h" #f ('seen 'trashed)) ("2.b.h" #t ())) ("cur/" "new/" "new/2.b.h" "tmp/") 'value)

### uids! gives UIDs in KEY order, keeps them, drops gone ones and never reuses one

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(File write-all (Str8 append root "/cur/2.b.h:2,") "A: 1\n\n")
(File write-all (Str8 append root "/new/1.a.h") "A: 1\n\n")
(def one (Maildir uids! root (list "INBOX")))
(File unlink (Str8 append root "/new/1.a.h"))
(File write-all (Str8 append root "/new/0.z.h") "A: 1\n\n")
(def two (Maildir uids! root (list "INBOX")))
(def three (Maildir uids! root (list "INBOX")))
(def r (list (rest one) (rest two) (equal? two three) (str=? (first one) (first two))
             (let ((ls (Str8 split "\n" (File read-all (Str8 append root "/x-lib-mail-uids"))))) (pair (Str8 replace (first one) "VALIDITY" (first ls)) (rest ls)))
             (File list-dir (Str8 append root "/tmp"))))
(%spec-rm root)
r
```
---
    ((3 ((1 . "1.a.h") (2 . "2.b.h"))) (4 ((2 . "2.b.h") (3 . "0.z.h"))) #t #t ("x-lib-mail-uids 1 VALIDITY 4" "2 2.b.h" "3 0.z.h" "") ())

### a file in another format starts over under a new UIDVALIDITY

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(File write-all (Str8 append root "/new/1.a.h") "A: 1\n\n")
(File write-all (Str8 append root "/x-lib-mail-uids") "something else\n7 1.a.h\n")
(def u (Maildir uids! root (list "INBOX")))
(%spec-rm root)
(rest u)
```
---
    (2 ((1 . "1.a.h")))

### info reads one message's INFO, found by its key

```x
(import mail/maildir)
(def root (%spec-root))
(Maildir create! root (list "INBOX"))
(File write-all (Str8 append root "/cur/1.a.h:2,S") "From: ann@example.org\nSubject: one\n\nfirst\n")
(def i (Maildir info root (list "INBOX") (first (Maildir entries root (list "INBOX")))))
(def r (list (rest (Assoc find 'subject i)) (rest (Assoc find 'from i)) (rest (Assoc find 'size i))))
(%spec-rm root)
r
```
---
    ("one" "ann@example.org" 42)
