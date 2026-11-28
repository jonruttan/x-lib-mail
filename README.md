# x-lib-mail

Mail for [x-lang](https://github.com/jonruttan/x-lang), written in x: Internet
messages, MIME, Maildir stores, SMTP, and an IMAP client and server so far,
with POP3 to follow.

x-lib-mail holds the bundle `mail`. It is a library: it has modules and no
entry, so there is nothing to start with `x -l`. A program imports what it
uses.

```x
(import mail/mime)
(Mime parts (Message parse text))
```

## Modules

| Module | Class | |
|---|---|---|
| `mail/message` | `Message` | an Internet message (RFC 5322): its fields and body, encoded words (RFC 2047) and address lists |
| `mail/mime` | `Mime` | MIME bodies (RFC 2045, 2046): Content-Type parameters, base64 and quoted-printable, multipart split and built |
| `mail/maildir` | `Maildir` | a Maildir++ store: folders, messages and their flags, delivery and moves |
| `mail/smtp` | `Smtp` | SMTP (RFC 5321) client and server, with STARTTLS (RFC 3207) and AUTH PLAIN and LOGIN (RFC 4954) |
| `mail/imap` | `Imap` | an IMAP client (RFC 9051 IMAP4rev2, RFC 3501 IMAP4rev1) with the calls of `mail/maildir`, and an IMAP4rev1 server over Maildir stores |
| `mail/wire` | `Wire` | the connection SMTP and IMAP talk over: a socket, TLS on a socket, or a script for tests |
| `mail/utf7` | `Utf7` | IMAP's modified UTF-7 (RFC 3501 5.1.3), the form of a mailbox name |

A message is `(FIELDS . BODY)`: `FIELDS` is a list of `(NAME . VALUE)` strings
in order and `BODY` is the text after the blank line. A message is text: RFC
5322 has no NUL in a message, so a STRING holds a whole one. A decoded body can
hold NULs, so `Mime decode-region` returns it as a region.

A Maildir store is a root directory and its Maildir++ folders. A folder is a
list of names: `("INBOX")` is the root, `("Lists" "x-lang")` is
`ROOT/.Lists.x-lang`, each name written in IMAP's modified UTF-7. A message is
an entry `(KEY NEW? FLAGS INFO)`: its file's unique name, whether it is still
in `new/`, the flags its name carries, and its header fields, time and size
under the keys an IMAP entry's `INFO` has.

```x
(import mail/maildir)
(import mail/message)
(def inbox (list "INBOX"))
(def e (first (Maildir messages "/home/me/Maildir" inbox)))
(Message field (Message parse (Maildir read "/home/me/Maildir" inbox e)) "Subject")
(Maildir flag! "/home/me/Maildir" inbox e (list (lit seen)))
```

```x
(import mail/mime)
(def m (Message add (Mime multipart "mixed"
                      (list (Mime text "See attached.")
                            (Mime attachment "a.bin" "application/octet-stream" (Bytes of-hex "0001"))))
                    "Subject" "files"))
(Message write m)
```

An SMTP session runs over a wire: a socket, TLS on a socket, or a script that
runs either side with no network. The server runs one session and asks the
caller's functions which recipients to take, whether a password is right, and
what to do with each message; accepting connections is the caller's.

```x
(import mail/smtp)
(def s (Smtp connect "127.0.0.1" 587))
(Smtp hello s "client.example")
(Smtp starttls s)
(Smtp auth s "ann" "secret")
(Smtp send s "ann@example.org" (list "bo@example.net") message)
(Smtp quit s)
```

An IMAP connection takes the Maildir calls with the connection in the root's
place: `folders`, `messages`, `read`, `flag!`, `move!`, `create!`. A message is
an entry `(KEY NEW? FLAGS INFO)`: `KEY` is `"UIDVALIDITY.UID"`, `NEW?` is
`\Recent` (always `#f` under IMAP4rev2), `FLAGS` the same six symbols, and
`INFO` the envelope `messages` fetched. Unread is a `FLAGS` without `seen`,
never `NEW?`.

```x
(import mail/imap)
(def c (Imap connect "imap.example.org" 993 (list (lit tls))))
(Imap login c "ann" "secret")
(def inbox (list "INBOX"))
(def e (first (Imap messages c inbox)))
(Message field (Message parse (Imap read c inbox e)) "Subject")
(Imap flag! c inbox e (list (lit seen)))
(Imap logout c)
```

The IMAP server serves Maildir stores, IMAP4rev1 with LITERAL+, SASL-IR,
UIDPLUS, MOVE, UNSELECT and NAMESPACE, one session a call, as the SMTP server
does. Its functions say whether a password is right and where a user's
Maildir root is. Each folder keeps its UIDs in a file `x-lib-mail-uids`, which
`Maildir uids!` reads and writes. Of the flags it keeps the six, and
`\Recent` is a message SELECT found in `new/` and moved to `cur/`.

```x
(import mail/imap)
(import x/sys/socket)
(def l (Socket tcp-listen 143))
(Imap serve (Wire socket (Socket accept l))
  (list (pair (lit auth) (fn (_ user password) (str=? password "secret")))
        (pair (lit store) (fn (_ user) (Str8 append "/var/mail/" user)))
        (pair (lit pem) (File read-all "/etc/mail/key-and-certs.pem"))))
```

## Using it

Installed under x's `bundles/` directory, an import of a `mail/` module finds
it with nothing declared:

```sh
make install
```

A bundle that depends on it says so in its `bundle.xon`:

```x
(requires-bundle "mail")
```

## Working on it

```sh
make check
```

```sh
make doctest
```

## Licence

MIT No Attribution.
