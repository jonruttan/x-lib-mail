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
             (equal? (Maildir messages root (list "INBOX")) (list e))
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
(def r (Maildir messages root (list "INBOX")))
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
(def r (list f (%spec-tree root)))
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
(def r (list e f (File list-dir (Str8 append root "/cur"))))
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
             (Maildir flag! root (list "INBOX") e (list (lit seen) (lit trashed)))))
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
(def r (list m (Maildir messages root (list "INBOX")) (Maildir messages root (list "Trash"))))
(%spec-rm root)
r
```
---
    (("1.x.h" #f ('seen)) () (("1.x.h" #f ('seen))))
