# Imap: the client on a script wire
# @weight 1

Each case plays the server from a script: every response it sends, all of
it, in order, and a record of what the client wrote. Tags run a1, a2, ...
No network.

## the session

### capabilities from the greeting, or asked for

```x
(import mail/imap)
(def w (Wire script "* OK hi\r\n* CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED\r\na1 OK done\r\n"))
(list (Imap capabilities (Imap client w)) (Wire output w))
```
---
    (("IMAP4REV1" "STARTTLS" "LOGINDISABLED") "a1 CAPABILITY\r\n")

### a BYE greeting raises 'io

```x
(import mail/imap)
(guard (e (Err label e)) (Imap client (Wire script "* BYE busy\r\n")))
```
---
    'io

### LOGINDISABLED refuses LOGIN before anything is sent

```x
(import mail/imap)
(def w (Wire script "* OK [CAPABILITY IMAP4rev1 LOGINDISABLED] hi\r\n"))
(def c (Imap client w))
(list (guard (e (Err label e)) (Imap login c "u" "p")) (Wire output w))
```
---
    ('io "")

### LOGIN, capabilities asked for again, ENABLE IMAP4rev2

```x
(import mail/imap)
(def w (Wire script "* OK [CAPABILITY IMAP4rev1 IMAP4rev2 AUTH=PLAIN] hi\r\na1 OK in\r\n* CAPABILITY IMAP4rev1 IMAP4rev2 ENABLE MOVE\r\na2 OK done\r\n* ENABLED IMAP4rev2\r\na3 OK on\r\n"))
(def c (Imap client w))
(Imap login c "ann" "pa\"ss\\word")
(list (Imap rev2? c) (Imap capabilities c) (Str8 split "\r\n" (Wire output w)))
```
---
    (#t ("IMAP4REV1" "IMAP4REV2" "ENABLE" "MOVE") ("a1 LOGIN \"ann\" \"pa\\\"ss\\\\word\"" "a2 CAPABILITY" "a3 ENABLE IMAP4rev2" ""))

### a password past ASCII goes as a literal, after the server's continuation

```x
(import mail/imap)
(def w (Wire script "* OK [CAPABILITY IMAP4rev1] hi\r\n+ go on\r\na1 OK [CAPABILITY IMAP4rev1] in\r\n"))
(Imap login (Imap client w) "ann" "pässe")
(Wire output w)
```
---
    "a1 LOGIN \"ann\" {6}\r\npässe\r\n"

### a refused LOGIN raises 'io with the server's status

```x
(import mail/imap)
(def c (Imap client (Wire script "* OK [CAPABILITY IMAP4rev1] hi\r\na1 NO [AUTHENTICATIONFAILED] no\r\n")))
(guard (e (list (Err label e) (Err text e))) (Imap login c "u" "p"))
```
---
    ('io "Imap: LOGIN NO no")

### LOGOUT reads the BYE and the tagged OK

```x
(import mail/imap)
(def w (Wire script "* OK [CAPABILITY IMAP4rev1] hi\r\n* BYE bye\r\na1 OK done\r\n"))
(Imap logout (Imap client w))
(Wire output w)
```
---
    "a1 LOGOUT\r\n"

## folders

### LIST: INBOX first, \Noselect left out, names split and out of modified UTF-7

```x
(import mail/imap)
(def w (Wire script "* PREAUTH [CAPABILITY IMAP4rev1] hi\r\n* LIST (\\HasChildren \\Noselect) \"/\" Archive\r\n* LIST () \"/\" \"Sent\"\r\n* LIST (\\HasNoChildren) \"/\" Archive/2026\r\n* LIST () \"/\" Entw&APw-rfe\r\n* LIST () \"/\" inbox\r\n* LIST () \"/\" {8}\r\nR&-D \"x\"\r\na1 OK done\r\n"))
(list (Imap folders (Imap client w)) (Wire output w))
```
---
    ((("INBOX") ("Archive" "2026") ("Entwürfe") ("R&D \"x\"") ("Sent")) "a1 LIST \"\" \"*\"\r\n")

### a folder's name on the wire: the delimiter asked for once, names in modified UTF-7

```x
(import mail/imap)
(def w (Wire script "* PREAUTH [CAPABILITY IMAP4rev1] hi\r\n* LIST (\\Noselect) \".\" \"\"\r\na1 OK done\r\na2 OK made\r\na3 NO [ALREADYEXISTS] there\r\n* LIST () \".\" Entw&APw-rfe\r\na4 OK done\r\n"))
(def c (Imap client w))
(list (Imap create! c (list "Lists" "x-lang")) (Imap create! c (list "Entwürfe")) (Str8 split "\r\n" (Wire output w)))
```
---
    (("Lists" "x-lang") ("Entwürfe") ("a1 LIST \"\" \"\"" "a2 CREATE \"Lists.x-lang\"" "a3 CREATE \"Entw&APw-rfe\"" "a4 LIST \"\" \"Entw&APw-rfe\"" ""))

### a name with the delimiter in it raises 'value; CREATE refused raises 'io

```x
(import mail/imap)
(def c (Imap client (Wire script "* PREAUTH [CAPABILITY IMAP4rev1] hi\r\n* LIST (\\Noselect) \"/\" \"\"\r\na1 OK done\r\na2 NO [CANNOT] no\r\na3 OK done\r\n")))
(list (guard (e (Err label e)) (Imap create! c (list "a/b" "c")))
      (guard (e (Err label e)) (Imap create! c (list "x")))
      (guard (e (Err label e)) (Imap messages c ())))
```
---
    ('value 'io 'value)

## messages

### IMAP4rev1: SELECT, then entries in UID order with \Recent as NEW? and the envelope

```x
(import mail/imap)
(def w (Wire script (Str8 join "\r\n" (list
  "* PREAUTH [CAPABILITY IMAP4rev1] hi"
  "* 2 EXISTS" "* 1 RECENT" "* OK [UIDVALIDITY 3857529045] v" "* OK [UIDNEXT 12] n" "a1 OK [READ-WRITE] done"
  "* 2 FETCH (UID 11 FLAGS (\\Recent) INTERNALDATE \"23-Nov-2026 10:00:00 +0000\" RFC822.SIZE 120 ENVELOPE (\"Mon, 23 Nov 2026 10:00:00 +0000\" {10}"
  "Two (more)  ((\"Ann B\" NIL \"ann\" \"example.org\")) NIL NIL ((NIL NIL \"me\" \"example.org\")) NIL NIL \"<1@x>\" \"<2@x>\"))"
  "* 1 FETCH (UID 9 FLAGS (\\Seen \\Answered $Forwarded $Junk) INTERNALDATE \"22-Nov-2026 09:00:00 +0000\" RFC822.SIZE 99 ENVELOPE (NIL \"One\" ((NIL NIL \"bo\" \"example.org\") (NIL NIL \"cy\" \"example.org\")) NIL NIL NIL NIL NIL NIL NIL))"
  "a2 OK done" ""))))
(def c (Imap client w))
(list (Imap messages c (list "INBOX")) (Str8 split "\r\n" (Wire output w)))
```
---
    ((("3857529045.9" #f ('passed 'replied 'seen) (('date) ('from . "bo@example.org, cy@example.org") ('to) ('cc) ('subject . "One") ('message-id) ('in-reply-to) ('internal-date . "22-Nov-2026 09:00:00 +0000") ('size . 99))) ("3857529045.11" #t () (('date . "Mon, 23 Nov 2026 10:00:00 +0000") ('from . "Ann B <ann@example.org>") ('to . "me@example.org") ('cc) ('subject . "Two (more)") ('message-id . "<2@x>") ('in-reply-to . "<1@x>") ('internal-date . "23-Nov-2026 10:00:00 +0000") ('size . 120)))) ("a1 SELECT \"INBOX\"" "a2 UID FETCH 1:* (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)" ""))

### IMAP4rev2: NEW? is #f; an empty folder sends no FETCH; a selected one is not selected again

```x
(import mail/imap)
(def w (Wire script (Str8 join "\r\n" (list
  "* PREAUTH [CAPABILITY IMAP4rev2] hi"
  "* LIST (\\Noselect) \"/\" \"\"" "a1 OK done"
  "* 0 EXISTS" "* OK [UIDVALIDITY 5] v" "a2 OK done"
  "* 1 EXISTS" "* OK [UIDVALIDITY 6] v" "a3 OK done"
  "* 1 FETCH (UID 3 FLAGS (\\Recent \\Draft) ENVELOPE (NIL NIL NIL NIL NIL NIL NIL NIL NIL NIL))" "a4 OK done"
  "* 1 FETCH (FLAGS (\\Seen))" "* 1 FETCH (UID 3 FLAGS (\\Draft) ENVELOPE (NIL NIL NIL NIL NIL NIL NIL NIL NIL NIL))" "a5 OK done" ""))))
(def c (Imap client w))
(list (Imap rev2? c) (Imap messages c (list "Empty"))
      (List map (fn (_ e) (List init e)) (Imap messages c (list "Drafts")))
      (List map (fn (_ e) (List init e)) (Imap messages c (list "Drafts")))
      (Str8 split "\r\n" (Wire output w)))
```
---
    (#t () (("6.3" #f ('draft))) (("6.3" #f ('draft))) ("a1 LIST \"\" \"\"" "a2 SELECT \"Empty\"" "a3 SELECT \"Drafts\"" "a4 UID FETCH 1:* (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)" "a5 UID FETCH 1:* (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)" ""))

### read: BODY.PEEK[] and the whole literal, CRLF and all

```x
(import mail/imap)
(def w (Wire script "* PREAUTH [CAPABILITY IMAP4rev1] hi\r\n* 1 EXISTS\r\n* OK [UIDVALIDITY 7] v\r\na1 OK done\r\n* 1 FETCH (UID 4 BODY[] {23}\r\nSubject: hi\r\n\r\n(body)\r\n)\r\na2 OK done\r\n"))
(def c (Imap client w))
(list (Imap read c (list "INBOX") (list "7.4" #f ())) (Str8 split "\r\n" (Wire output w)))
```
---
    ("Subject: hi\r\n\r\n(body)\r\n" ("a1 SELECT \"INBOX\"" "a2 UID FETCH 4 (BODY.PEEK[])" ""))

### an entry from another UIDVALIDITY raises 'value; a message the server lacks too

```x
(import mail/imap)
(def c (Imap client (Wire script "* PREAUTH [CAPABILITY IMAP4rev1] hi\r\n* 1 EXISTS\r\n* OK [UIDVALIDITY 7] v\r\na1 OK done\r\na2 OK done\r\n")))
(list (guard (e (Err label e)) (Imap read c (list "INBOX") (list "6.4" #f ())))
      (guard (e (Err label e)) (Imap read c (list "INBOX") (list "7.4" #f ()))))
```
---
    ('value 'value)

### flag!: the wanted flags added, the other five taken off, the entry's INFO kept

```x
(import mail/imap)
(def w (Wire script "* PREAUTH [CAPABILITY IMAP4rev1] hi\r\n* 1 EXISTS\r\n* OK [UIDVALIDITY 7] v\r\na1 OK done\r\na2 OK done\r\na3 OK done\r\n"))
(def c (Imap client w))
(list (Imap flag! c (list "INBOX") (list "7.4" #t () (list (pair 'size 9))) (list 'seen 'flagged))
      (guard (e (Err label e)) (Imap flag! c (list "INBOX") (list "7.4" #f ()) (list 'junk)))
      (Str8 split "\r\n" (Wire output w)))
```
---
    (("7.4" #t ('flagged 'seen) (('size . 9))) 'value ("a1 SELECT \"INBOX\"" "a2 UID STORE 4 +FLAGS.SILENT (\\Flagged \\Seen)" "a3 UID STORE 4 -FLAGS.SILENT (\\Draft $Forwarded \\Answered \\Deleted)" ""))

### move!: MOVE where the server has it, the new KEY from COPYUID

```x
(import mail/imap)
(def w (Wire script "* PREAUTH [CAPABILITY IMAP4rev1 MOVE UIDPLUS] hi\r\n* 1 EXISTS\r\n* OK [UIDVALIDITY 7] v\r\na1 OK done\r\n* LIST () \"/\" \"\"\r\na2 OK done\r\n* OK [COPYUID 8 4 30] moved\r\n* 1 EXPUNGE\r\na3 OK done\r\n"))
(def c (Imap client w))
(list (Imap move! c (list "INBOX") (list "7.4" #f (list 'seen)) (list "Archive" "2026")) (Str8 split "\r\n" (Wire output w)))
```
---
    (("8.30" #f ('seen)) ("a1 SELECT \"INBOX\"" "a2 LIST \"\" \"\"" "a3 UID MOVE 4 \"Archive/2026\"" ""))

### move! without MOVE: COPY, the deleted flag, UID EXPUNGE under UIDPLUS

```x
(import mail/imap)
(def w (Wire script "* PREAUTH [CAPABILITY IMAP4rev1 UIDPLUS] hi\r\n* 1 EXISTS\r\n* OK [UIDVALIDITY 7] v\r\na1 OK done\r\n* LIST () \"/\" \"\"\r\na2 OK done\r\na3 OK [COPYUID 8 4 31] copied\r\na4 OK done\r\n* 1 EXPUNGE\r\na5 OK done\r\n"))
(def c (Imap client w))
(list (first (Imap move! c (list "INBOX") (list "7.4" #f ()) (list "Trash"))) (Str8 split "\r\n" (Wire output w)))
```
---
    ("8.31" ("a1 SELECT \"INBOX\"" "a2 LIST \"\" \"\"" "a3 UID COPY 4 \"Trash\"" "a4 UID STORE 4 +FLAGS.SILENT (\\Deleted)" "a5 UID EXPUNGE 4" ""))

### search: SEARCH under IMAP4rev1, ESEARCH's sets under IMAP4rev2, KEYs in UID order

```x
(import mail/imap)
(def one (Imap client (Wire script "* PREAUTH [CAPABILITY IMAP4rev1] hi\r\n* 3 EXISTS\r\n* OK [UIDVALIDITY 7] v\r\na1 OK done\r\n* SEARCH 10 9\r\na2 OK done\r\n")))
(def two (Imap client (Wire script "* PREAUTH [CAPABILITY IMAP4rev2] hi\r\n* 3 EXISTS\r\n* OK [UIDVALIDITY 7] v\r\na1 OK done\r\n* ESEARCH (TAG \"a2\") UID ALL 5:3,9\r\na2 OK done\r\n")))
(list (Imap search one (list "INBOX") "UNSEEN") (Imap search two (list "INBOX") "UNSEEN"))
```
---
    (("7.9" "7.10") ("7.3" "7.4" "7.5" "7.9"))

### append: the flags, the text as a literal with CRLF line ends, the KEY from APPENDUID

```x
(import mail/imap)
(def w (Wire script "* PREAUTH [CAPABILITY IMAP4rev1 UIDPLUS] hi\r\n* LIST () \"/\" \"\"\r\na1 OK done\r\n+ ready\r\na2 OK [APPENDUID 8 32] done\r\n"))
(list (Imap append (Imap client w) (list "Sent") "Subject: hi\n\nbody\n" (list 'seen)) (Wire output w))
```
---
    (("8.32" #f ('seen)) "a1 LIST \"\" \"\"\r\na2 APPEND \"Sent\" (\\Seen) {21}\r\nSubject: hi\r\n\r\nbody\r\n\r\n")

### append refused before the literal: the literal is never sent

```x
(import mail/imap)
(def w (Wire script "* PREAUTH [CAPABILITY IMAP4rev1] hi\r\n* LIST () \"/\" \"\"\r\na1 OK done\r\na2 NO [TRYCREATE] no folder\r\n"))
(list (guard (e (Err label e)) (Imap append (Imap client w) (list "Gone") "x")) (Wire output w))
```
---
    ('io "a1 LIST \"\" \"\"\r\na2 APPEND \"Gone\" {1}\r\n")
