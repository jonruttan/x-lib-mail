# x-lib-mail

Mail for [x-lang](https://github.com/jonruttan/x-lang), written in x: Internet
messages and MIME so far, with SMTP, POP3, IMAP and Maildir to follow.

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

A message is `(FIELDS . BODY)`: `FIELDS` is a list of `(NAME . VALUE)` strings
in order and `BODY` is the text after the blank line. A message is text: RFC
5322 has no NUL in a message, so a STRING holds a whole one. A decoded body can
hold NULs, so `Mime decode-region` returns it as a region.

```x
(import mail/mime)
(def m (Message add (Mime multipart "mixed"
                      (list (Mime text "See attached.")
                            (Mime attachment "a.bin" "application/octet-stream" (Bytes of-hex "0001"))))
                    "Subject" "files"))
(Message write m)
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
