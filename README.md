# x-lib-mail

Mail for [x-lang](https://github.com/jonruttan/x-lang), written in x: Internet
messages, MIME, Maildir stores and SMTP so far, with POP3 and IMAP to follow.

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

A message is `(FIELDS . BODY)`: `FIELDS` is a list of `(NAME . VALUE)` strings
in order and `BODY` is the text after the blank line. A message is text: RFC
5322 has no NUL in a message, so a STRING holds a whole one. A decoded body can
hold NULs, so `Mime decode-region` returns it as a region.

A Maildir store is a root directory and its Maildir++ folders. A folder is a
list of names: `("INBOX")` is the root, `("Lists" "x-lang")` is
`ROOT/.Lists.x-lang`, each name written in IMAP's modified UTF-7. A message is
an entry `(KEY NEW? FLAGS)`: its file's unique name, whether it is still in
`new/`, and the flags its name carries.

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
