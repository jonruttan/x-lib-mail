# Imap serve: an IMAP server over Maildir stores
# @weight 2

Each case plays a client's lines to the server on a script wire and reads
back what the server wrote, one line a string. UIDVALIDITY values come from
the clock, so they read V.

## the fixture

### a store with three messages, and a session over it

```x
(import mail/imap)
(import mail/maildir)
(import mail/wire)
(import x/sys/file)
(def %is-text
  (lit ("From: Ann <ann@example.org>\nTo: bo@example.org\nSubject: Hello\nMessage-ID: <1@example.org>\nDate: Fri, 27 Nov 2026 10:00:00 +0000\n\nhi there\n"
        "From: bo@example.org\nTo: ann@example.org\nSubject: Re: Hello\nContent-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: text/plain\n\nsee this\n--b\nContent-Type: application/octet-stream\nContent-Transfer-Encoding: base64\n\nAAEC\n--b--\n"
        "From: cy@example.org\nSubject: Late\n\nlong body text\n")))
(def %is-store
  (fn (_)
    (def root (%spec-root))
    (Maildir create! root (list "INBOX"))
    (Maildir create! root (list "Archive"))
    (File write-all (Str8 append root "/cur/1.a.h:2,S") (first %is-text))
    (File write-all (Str8 append root "/cur/2.b.h:2,") (first (rest %is-text)))
    (File write-all (Str8 append root "/new/3.c.h") (first (rest (rest %is-text))))
    root))
(def %is-opts
  (fn (_ root)
    (list (pair 'auth (fn (_ u p) (if (str=? u "ann") (str=? p "pw") #f)))
          (pair 'store (fn (_ u) root))
          (list 'auth-in-clear))))
; s with the digits after each of words read as V
(def %is-mask
  (fn (_ s)
    (List fold
      (fn (_ s word)
        (let go ((s s) (from 0))
          (def at (Str8 index-of word (str-byte-sub s from (int- (str-byte-len s) from))))
          (if (null? at) s
            (let ((i (int+ from (int+ at (str-byte-len word)))))
              (def j (let skip ((j i)) (if (if (int< j (str-byte-len s)) (Str8 includes? (str-byte-sub s j 1) "0123456789") #f) (skip (int+ j 1)) j)))
              (go (Str8 str (str-byte-sub s 0 i) "V" (str-byte-sub s j (int- (str-byte-len s) j))) (int+ i 1))))))
      s (list "UIDVALIDITY " "COPYUID " "APPENDUID "))))
; the server's lines for the client's, the greeting left out
(def %is-session
  (fn (_ root lines)
    (def in (Str8 join "" (List map (fn (_ l) (Str8 append l "\r\n")) lines)))
    (def out (%is-mask (Wire output (Imap serve (Wire script in) (%is-opts root)))))
    (rest (List init (Str8 split "\r\n" out)))))
(def %is-run
  (fn (_ lines)
    (def root (%is-store))
    (def r (%is-session root lines))
    (%spec-rm root)
    r))
(%is-mask "a [UIDVALIDITY 123] b [COPYUID 9 1 2]")
```
---
    "a [UIDVALIDITY V] b [COPYUID V 1 2]"

## a session

### LOGIN, SELECT, then FETCH of sizes, ENVELOPE, BODYSTRUCTURE and header fields

```x
(%is-run (list "a LOGIN ann pw" "b SELECT INBOX" "c FETCH 1:* (UID FLAGS RFC822.SIZE ENVELOPE)" "d FETCH 2 BODYSTRUCTURE" "e FETCH 1 BODY[HEADER.FIELDS (Subject)]" "f LOGOUT"))
```
---
    ("a OK [CAPABILITY IMAP4rev1 LITERAL+ SASL-IR UIDPLUS MOVE UNSELECT NAMESPACE] Logged in" "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)" "* 3 EXISTS" "* 1 RECENT" "* OK [UNSEEN 2] First unseen" "* OK [UIDVALIDITY V] UIDs valid" "* OK [UIDNEXT 4] Predicted next UID" "* OK [PERMANENTFLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)] Flags kept" "b OK [READ-WRITE] SELECT completed" "* 1 FETCH (UID 1 FLAGS (\\Seen) RFC822.SIZE 145 ENVELOPE (\"Fri, 27 Nov 2026 10:00:00 +0000\" \"Hello\" ((\"Ann\" NIL \"ann\" \"example.org\")) ((\"Ann\" NIL \"ann\" \"example.org\")) ((\"Ann\" NIL \"ann\" \"example.org\")) ((NIL NIL \"bo\" \"example.org\")) NIL NIL NIL \"<1@example.org>\"))" "* 2 FETCH (UID 2 FLAGS () RFC822.SIZE 246 ENVELOPE (NIL \"Re: Hello\" ((NIL NIL \"bo\" \"example.org\")) ((NIL NIL \"bo\" \"example.org\")) ((NIL NIL \"bo\" \"example.org\")) ((NIL NIL \"ann\" \"example.org\")) NIL NIL NIL NIL))" "* 3 FETCH (UID 3 FLAGS (\\Recent) RFC822.SIZE 55 ENVELOPE (NIL \"Late\" ((NIL NIL \"cy\" \"example.org\")) ((NIL NIL \"cy\" \"example.org\")) ((NIL NIL \"cy\" \"example.org\")) NIL NIL NIL NIL NIL))" "c OK FETCH completed" "* 2 FETCH (BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" 8 1 NIL NIL NIL NIL)(\"APPLICATION\" \"OCTET-STREAM\" NIL NIL NIL \"BASE64\" 4 NIL NIL NIL NIL) \"MIXED\" (\"BOUNDARY\" \"b\") NIL NIL NIL))" "d OK FETCH completed" "* 1 FETCH (BODY[HEADER.FIELDS (Subject)] {18}" "Subject: Hello" "" ")" "e OK FETCH completed" "* BYE Logging out" "f OK LOGOUT completed")

### FETCH of parts and partials sets \\Seen; STORE, SEARCH and EXPUNGE

```x
(%is-run (list "a LOGIN ann pw" "b SELECT INBOX" "c FETCH 2 (BODY.PEEK[2.1]<0.3> BODY[1] BODY.PEEK[2.MIME])" "d FETCH 3 BODY[TEXT]" "e STORE 1 +FLAGS (\\Deleted \\Flagged)" "f STORE 2 FLAGS.SILENT (\\Answered)" "g SEARCH UNSEEN" "h UID SEARCH OR FROM cy SUBJECT re" "i SEARCH NOT SEEN LARGER 100" "j SEARCH TEXT \"see THIS\"" "k EXPUNGE" "l UID FETCH 1:* FLAGS" "m LOGOUT"))
```
---
    ("a OK [CAPABILITY IMAP4rev1 LITERAL+ SASL-IR UIDPLUS MOVE UNSELECT NAMESPACE] Logged in" "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)" "* 3 EXISTS" "* 1 RECENT" "* OK [UNSEEN 2] First unseen" "* OK [UIDVALIDITY V] UIDs valid" "* OK [UIDNEXT 4] Predicted next UID" "* OK [PERMANENTFLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)] Flags kept" "b OK [READ-WRITE] SELECT completed" "* 2 FETCH (BODY[2.1]<0> \"AAE\" BODY[1] \"see this\" BODY[2.MIME] {77}" "Content-Type: application/octet-stream" "Content-Transfer-Encoding: base64" "" " FLAGS (\\Seen))" "c OK FETCH completed" "* 3 FETCH (BODY[TEXT] {16}" "long body text" " FLAGS (\\Seen \\Recent))" "d OK FETCH completed" "* 1 FETCH (FLAGS (\\Flagged \\Seen \\Deleted))" "e OK STORE completed" "f OK STORE completed" "* SEARCH 2" "g OK SEARCH completed" "* SEARCH 2 3" "h OK UID SEARCH completed" "* SEARCH 2" "i OK SEARCH completed" "* SEARCH 2" "j OK SEARCH completed" "* 1 EXPUNGE" "k OK EXPUNGE completed" "* 1 FETCH (UID 2 FLAGS (\\Answered))" "* 2 FETCH (UID 3 FLAGS (\\Seen \\Recent))" "l OK UID FETCH completed" "* BYE Logging out" "m OK LOGOUT completed")

### CREATE, LIST with * and %, COPY and MOVE with COPYUID, STATUS

```x
(%is-run (list "a LOGIN ann pw" "b CREATE Lists/x-lang" "c CREATE Archive" "d LIST \"\" *" "e LIST \"\" %" "f SELECT INBOX" "g COPY 1:2 Archive" "h UID MOVE 3 Lists/x-lang" "i STATUS Archive (MESSAGES UNSEEN UIDNEXT RECENT)" "j STATUS Lists/x-lang (MESSAGES)" "k COPY 1 Nowhere" "l LOGOUT"))
```
---
    ("a OK [CAPABILITY IMAP4rev1 LITERAL+ SASL-IR UIDPLUS MOVE UNSELECT NAMESPACE] Logged in" "b OK CREATE completed" "c NO [ALREADYEXISTS] The folder is there" "* LIST () \"/\" \"INBOX\"" "* LIST () \"/\" \"Archive\"" "* LIST (\\Noselect) \"/\" \"Lists\"" "* LIST () \"/\" \"Lists/x-lang\"" "d OK LIST completed" "* LIST () \"/\" \"INBOX\"" "* LIST () \"/\" \"Archive\"" "* LIST (\\Noselect) \"/\" \"Lists\"" "e OK LIST completed" "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)" "* 3 EXISTS" "* 1 RECENT" "* OK [UNSEEN 2] First unseen" "* OK [UIDVALIDITY V] UIDs valid" "* OK [UIDNEXT 4] Predicted next UID" "* OK [PERMANENTFLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)] Flags kept" "f OK [READ-WRITE] SELECT completed" "g OK [COPYUID V 1,2 1,2] COPY completed" "* OK [COPYUID V 3 1] Moved" "* 3 EXPUNGE" "h OK MOVE completed" "* STATUS \"Archive\" (MESSAGES 2 UNSEEN 1 UIDNEXT 3 RECENT 0)" "i OK STATUS completed" "* STATUS \"Lists/x-lang\" (MESSAGES 1)" "j OK STATUS completed" "k NO [TRYCREATE] No folder by that name" "* BYE Logging out" "l OK LOGOUT completed")

### APPEND by a literal and by LITERAL+, with APPENDUID; a literal past the limit is refused

```x
(%is-run (list "a LOGIN ann pw" "b APPEND Archive (\\Seen) {11}" "To: x" "" "hi" "c APPEND INBOX {6+}" "A: 1" "" "d SELECT INBOX" "e NOOP" "f APPEND INBOX {99999999}" "g LOGOUT"))
```
---
    ("a OK [CAPABILITY IMAP4rev1 LITERAL+ SASL-IR UIDPLUS MOVE UNSELECT NAMESPACE] Logged in" "+ Ready for literal data" "b OK [APPENDUID V 1] APPEND completed" "c OK [APPENDUID V 2] APPEND completed" "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)" "* 4 EXISTS" "* 2 RECENT" "* OK [UNSEEN 2] First unseen" "* OK [UIDVALIDITY V] UIDs valid" "* OK [UIDNEXT 5] Predicted next UID" "* OK [PERMANENTFLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)] Flags kept" "d OK [READ-WRITE] SELECT completed" "e OK NOOP completed" "f NO [TOOBIG] A literal past the size limit" "* BYE Logging out" "g OK LOGOUT completed")

### A bad password, AUTHENTICATE PLAIN with SASL-IR, EXAMINE read-only, commands out of state

```x
(%is-run (list "a LOGIN ann nope" "b AUTHENTICATE PLAIN AGFubgBwdw==" "c LOGIN ann pw" "d FETCH 1 FLAGS" "e EXAMINE INBOX" "f STORE 1 +FLAGS (\\Seen)" "g FETCH 2 BODY[TEXT]" "h FETCH 2 FLAGS" "i FROB" "j" "k FETCH 1 BODY.PEEK" "l CLOSE" "m LOGOUT"))
```
---
    ("a NO [AUTHENTICATIONFAILED] Authentication failed" "b OK [CAPABILITY IMAP4rev1 LITERAL+ SASL-IR UIDPLUS MOVE UNSELECT NAMESPACE] Logged in" "c BAD Not in this state" "d BAD Not in this state" "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)" "* 3 EXISTS" "* 1 RECENT" "* OK [UNSEEN 2] First unseen" "* OK [UIDVALIDITY V] UIDs valid" "* OK [UIDNEXT 4] Predicted next UID" "* OK [PERMANENTFLAGS ()] Read-only" "e OK [READ-ONLY] EXAMINE completed" "f NO [READ-ONLY] The folder is selected read-only" "* 2 FETCH (BODY[TEXT] {138}" "--b" "Content-Type: text/plain" "" "see this" "--b" "Content-Type: application/octet-stream" "Content-Transfer-Encoding: base64" "" "AAEC" "--b--" ")" "g OK FETCH completed" "* 2 FETCH (FLAGS ())" "h OK FETCH completed" "i BAD Command not recognized" "j BAD A command is a tag and a name" "k BAD a FETCH item this server does not give: BODY.PEEK" "l OK CLOSE completed" "* BYE Logging out" "m OK LOGOUT completed")

### AUTHENTICATE PLAIN by a continuation; BODY[] sets \\Seen; SELECT after CLOSE shows no \\Recent

```x
(%is-run (list "a AUTHENTICATE PLAIN" "AGFubgBwdw==" "b SELECT inbox" "c FETCH 2 BODY[]" "d FETCH 2 FLAGS" "e CLOSE" "f SELECT INBOX" "g LOGOUT"))
```
---
    ("+ " "a OK [CAPABILITY IMAP4rev1 LITERAL+ SASL-IR UIDPLUS MOVE UNSELECT NAMESPACE] Logged in" "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)" "* 3 EXISTS" "* 1 RECENT" "* OK [UNSEEN 2] First unseen" "* OK [UIDVALIDITY V] UIDs valid" "* OK [UIDNEXT 4] Predicted next UID" "* OK [PERMANENTFLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)] Flags kept" "b OK [READ-WRITE] SELECT completed" "* 2 FETCH (BODY[] {246}" "From: bo@example.org" "To: ann@example.org" "Subject: Re: Hello" "Content-Type: multipart/mixed; boundary=b" "" "--b" "Content-Type: text/plain" "" "see this" "--b" "Content-Type: application/octet-stream" "Content-Transfer-Encoding: base64" "" "AAEC" "--b--" " FLAGS (\\Seen))" "c OK FETCH completed" "* 2 FETCH (FLAGS (\\Seen))" "d OK FETCH completed" "e OK CLOSE completed" "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)" "* 3 EXISTS" "* 0 RECENT" "* OK [UNSEEN 3] First unseen" "* OK [UIDVALIDITY V] UIDs valid" "* OK [UIDNEXT 4] Predicted next UID" "* OK [PERMANENTFLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded)] Flags kept" "f OK [READ-WRITE] SELECT completed" "* BYE Logging out" "g OK LOGOUT completed")

