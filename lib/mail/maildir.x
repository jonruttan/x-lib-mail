; maildir.x -- Maildir: a mail store of one file a message, in Maildir++ folders.
;
; A folder is named by a list of names: ("INBOX") is the root directory itself,
; ("Sent") is ROOT/.Sent and ("Lists" "x-lang") is ROOT/.Lists.x-lang.  Each
; name is written on disk in IMAP's modified UTF-7 (RFC 3501 5.1.3), with "."
; and "/" encoded too, so no name can split into two or leave the root.
;
; A message is an entry (KEY NEW? FLAGS INFO): KEY the file's unique name,
; NEW? true while it sits in new/, FLAGS the symbols draft flagged passed
; replied seen trashed that its name carries, in that order, INFO its header
; fields, time and size with mail/imap's keys (messages reads them; flag! and
; move! keep them).  The entry gives the file's path; when another program has
; renamed the file since, it is found again by its KEY.  Flag letters this module has no symbol for (a server's keywords) are
; kept on the file whenever it is renamed.
(module mail/maildir)

(import x/core/doors char->int int+ int- int< int= str-byte-len str-byte-ref str-byte-sub str-make)
(import mail/utf7)
(import mail/message)
(import x/sys/date)
(import x/type/assoc)
(import x/sys/file)
(import x/sys/posix)

(def %fail (fn (_ what data) (Err raise (lit value) (Str8 append "Maildir: " what) data)))

(def %byte (fn (_ s i) (char->int (str-byte-ref s i))))

(def %flag-letters (lit ((draft . 68) (flagged . 70) (passed . 80) (replied . 82) (seen . 83) (trashed . 84))))

; A folder name as a directory part: modified UTF-7 with "." and "/" in runs
; too, since "." joins the parts and "/" is a path step.
(def %encode-name (fn (_ name) (Utf7 encode-with name "./")))

(def %decode-name (fn (_ s) (Utf7 decode s)))

; --- Folders ---

(def %inbox? (fn (_ folder) (if (null? (rest folder)) (Str8 ci=? (first folder) "INBOX") #f)))

(def %folder-dir
  (fn (_ root folder)
    (match
      ((if (pair? folder) (List all? (fn (_ s) (if (str? s) (int< 0 (str-byte-len s)) #f)) folder) #f) ())
      (#t (%fail "a folder is a list of names, none empty" folder)))
    (match
      ((%inbox? folder) root)
      (#t (Str8 append root "/." (Str8 join "." (List map %encode-name folder)))))))

; A directory part split at its dots, each part decoded.
(def %folder-of
  (fn (_ part)
    (def n (str-byte-len part))
    (let go ((i 0) (start 0) (acc ()))
      (match
        ((int= i n) (List reverse (pair (%decode-name (str-byte-sub part start (int- i start))) acc)))
        ((int= (%byte part i) 46)
          (go (int+ i 1) (int+ i 1) (pair (%decode-name (str-byte-sub part start (int- i start))) acc)))
        (#t (go (int+ i 1) start acc))))))

(def %maildir? (fn (_ dir) (eq? (File type (Str8 append dir "/cur")) (lit dir))))

; --- Entries ---

; The flag letters of a file name: the bytes after ":2,", or none.
(def %letters
  (fn (_ name)
    (def at (Str8 index-of ":2," name))
    (match
      ((null? at) ())
      (#t (let go ((i (int+ at 3)) (acc ()))
            (if (int= i (str-byte-len name)) (List reverse acc) (go (int+ i 1) (pair (%byte name i) acc))))))))

(def %key
  (fn (_ name)
    (def at (Str8 index-of ":" name))
    (if (null? at) name (str-byte-sub name 0 at))))

(def %int-in? (fn (_ c l) (List any? (fn (_ x) (int= x c)) l)))

(def %flags-of
  (fn (_ letters)
    (List map first (List filter (fn (_ f) (%int-in? (rest f) letters)) %flag-letters))))

(def %entry (fn (_ name new?) (list (%key name) new? (%flags-of (%letters name)))))

; The header of the file at path: its bytes up to the blank line, read a
; block at a time, none past 256 KB.
(def %head-max 262144)

(def %head
  (fn (_ path)
    (def fd (File open path (lit rdonly)))
    (when (int< fd 0) (error (Err from-errno fd (lit open) path)))
    (def buf (str-make 8192))
    (def ends
      (fn (_ s)
        (def a (Str8 index-of "\n\n" s))
        (def b (Str8 index-of "\n\r\n" s))
        (match ((null? a) b) ((null? b) a) ((int< a b) a) (#t b))))
    (def text
      (let go ((acc ""))
        (def at (ends acc))
        (match
          ((not (null? at)) (str-byte-sub acc 0 (int+ at 1)))
          ((int< %head-max (str-byte-len acc)) acc)
          (#t (let ((k (File read fd buf 8192)))
                (if (int< 0 k) (go (Str8 append acc (str-byte-sub buf 0 k))) acc))))))
    (File close fd)
    text))

(def %months (list "Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(def %month (fn (_ m) (let go ((l %months) (i 1)) (if (int= i m) (first l) (go (rest l) (int+ i 1))))))

(def %two (fn (_ n) (if (int< n 10) (Str8 str "0" n) (Str8 str n))))

; Unix seconds as IMAP writes a date-time: "23-Nov-2026 10:00:00 +0000".
(def %imap-date
  (fn (_ secs)
    (def d (Date from-unix secs))
    (def at (fn (_ k) (Assoc get k d)))
    (Str8 str (%two (at (lit day))) "-" (%month (at (lit month))) "-" (at (lit year)) " "
              (%two (at (lit hour))) ":" (%two (at (lit minute))) ":" (%two (at (lit second))) " +0000")))

; The entry with INFO: its header's fields, the file's time and size, as
; Imap messages answers them.
(def %with-info
  (fn (_ entry path)
    (def st (File stat path))
    (def head (%head path))
    ; a header line with no colon: the fields are nil, the listing goes on
    (def m (guard (e (if (eq? (Err label e) (lit value)) (pair () "") (error e))) (Message parse head)))
    (def f (fn (_ name) (Message field m name)))
    (List append entry
      (list (list (pair (lit date) (f "Date"))
                  (pair (lit from) (f "From"))
                  (pair (lit to) (f "To"))
                  (pair (lit cc) (f "Cc"))
                  (pair (lit subject) (f "Subject"))
                  (pair (lit message-id) (f "Message-ID"))
                  (pair (lit in-reply-to) (f "In-Reply-To"))
                  (pair (lit internal-date) (%imap-date (Assoc get (lit mtime) st)))
                  (pair (lit size) (Assoc get (lit size) st)))))))

; The letters for FLAGS and the unknown letters kept from a file's name,
; in ASCII order, each once.
(def %name-letters
  (fn (_ flags old)
    (def known (List map rest %flag-letters))
    (def wanted
      (List map
        (fn (_ f)
          (def l (List find (fn (_ p) (eq? (first p) f)) %flag-letters))
          (if (null? l) (%fail "no such flag" f) (rest l)))
        flags))
    (def all (List append wanted (List filter (fn (_ c) (not (%int-in? c known))) old)))
    (let go ((l (List sort (fn (_ a b) (int< a b)) all)) (acc ()))
      (match
        ((null? l) (bytes->str (List reverse acc)))
        ((if (pair? acc) (int= (first acc) (first l)) #f) (go (rest l) acc))
        (#t (go (rest l) (pair (first l) acc)))))))

(def %visible
  (fn (_ dir)
    (List filter (fn (_ name) (not (int= (%byte name 0) 46))) (File list-dir dir))))

; --- UIDs ---
;
; A folder's x-lib-mail-uids file keeps IMAP's UIDs for its messages: a line
; "x-lib-mail-uids 1 UIDVALIDITY NEXT", then a line "UID KEY" a message, UIDs
; ascending.  It is written whole into tmp/ and renamed over the old one.

(def %uid-file "x-lib-mail-uids")

; The lines of text, the text after the last LF a line of its own when not empty.
(def %lines
  (fn (_ text)
    (let go ((s text) (acc ()))
      (def at (Str8 index-of "\n" s))
      (match
        ((null? at) (List reverse (if (int= (str-byte-len s) 0) acc (pair s acc))))
        (#t (go (str-byte-sub s (int+ at 1) (int- (str-byte-len s) (int+ at 1))) (pair (str-byte-sub s 0 at) acc)))))))

; The file's (UIDVALIDITY NEXT PAIRS), PAIRS (UID . KEY); nil when it is not
; there or not this format.
(def %read-uids
  (fn (_ path)
    (if (not (eq? (File type path) (lit file)))
      ()
      (let ((lines (%lines (File read-all path))))
        (def head (if (pair? lines) (Str8 split " " (first lines)) ()))
        (def num (fn (_ s) (guard (_ ()) (%str->number s))))
        (if (if (int= (List length head) 4) (if (str=? (first head) %uid-file) (str=? (%nth head 1) "1") #f) #f)
          (let ((pairs (List map
                         (fn (_ l)
                           (def sp (Str8 index-of " " l))
                           (if (null? sp) () (pair (num (str-byte-sub l 0 sp)) (str-byte-sub l (int+ sp 1) (int- (str-byte-len l) (int+ sp 1))))))
                         (rest lines))))
            (if (List any? (fn (_ p) (if (null? p) #t (null? (first p)))) pairs)
              ()
              (list (%nth head 2) (num (%nth head 3)) pairs)))
          ())))))

(def %nth (fn (_ l i) (if (int= i 0) (first l) (%nth (rest l) (int- i 1)))))

(def %write-uids
  (fn (_ dir validity next pairs)
    (def text
      (Str8 join ""
        (pair (Str8 str %uid-file " 1 " validity " " next "\n")
              (List map (fn (_ p) (Str8 str (first p) " " (rest p) "\n")) pairs))))
    (def tmp (Str8 str dir "/tmp/" %uid-file "." (Sys getpid)))
    (File write-all tmp text)
    (File rename tmp (Str8 str dir "/" %uid-file))))

; A folder directory's messages as (ENTRY . PATH), new/ and cur/, in KEY order.
(def %listing
  (fn (_ dir)
    (def of (fn (_ sub new?) (List map (fn (_ name) (pair (%entry name new?) (Str8 str dir "/" sub "/" name))) (%visible (Str8 append dir (Str8 append "/" sub))))))
    (List sort (fn (_ a b) (Str8 <? (first (first a)) (first (first b)))) (List append (of "new" #t) (of "cur" #f)))))

; Where an entry's file is now: (SUB . NAME), SUB "new" or "cur".
(def %locate
  (fn (_ dir entry)
    (def key (first entry))
    (def sub (if (first (rest entry)) "new" "cur"))
    (def guess
      (if (first (rest entry))
        key
        (Str8 append key ":2," (%name-letters (first (rest (rest entry))) ()))))
    (match
      ((eq? (File type (Str8 append dir "/" sub "/" guess)) (lit file)) (pair sub guess))
      (#t
        (let look ((subs (list "new" "cur")))
          (match
            ((null? subs) (%fail "no message of that key" key))
            (#t
              (let ((hit (List find (fn (_ name) (str=? (%key name) key)) (%visible (Str8 append dir "/" (first subs))))))
                (if (null? hit) (look (rest subs)) (pair (first subs) hit))))))))))

; --- Delivery ---

; This host's name as a file name wants it: "/" and ":" written as octal.
(def %host
  (fn (_)
    (def h (Sys gethostname))
    (let go ((i 0) (acc ()))
      (match
        ((int= i (str-byte-len h)) (Str8 join "" (List reverse acc)))
        ((int= (%byte h i) 47) (go (int+ i 1) (pair "\\057" acc)))
        ((int= (%byte h i) 58) (go (int+ i 1) (pair "\\072" acc)))
        (#t (go (int+ i 1) (pair (str-byte-sub h i 1) acc)))))))

; Write text to the open fd and close it; a short write removes path and raises.
(def %write-fd
  (fn (_ fd path text)
    (def len (str-byte-len text))
    (def wrote (File write fd text len))
    (File close fd)
    (match
      ((int= wrote len) ())
      (#t (do (File unlink path)
              (error (Err from-errno (if (int< wrote 0) wrote -5) (lit write) path)))))))

; A fresh file in tmp/ holding text: its name.  A name another delivery took in
; the same microsecond is tried again with the clock read afresh.
(def %write-tmp
  (fn (_ dir text)
    (def host (%host))
    (let attempt ((left 16))
      (def t (Sys time-of-day))
      (def name (Str8 str (first t) ".M" (rest t) "P" (Sys getpid) "." host))
      (def path (Str8 append dir "/tmp/" name))
      (def fd (File open path (list (lit wronly) (lit creat) (lit excl)) 384))
      (match
        ((if (int= fd -17) (int< 0 left) #f) (attempt (int- left 1)))
        ((int< fd 0) (error (Err from-errno fd (lit open) path)))
        (#t (do (%write-fd fd path text) name))))))

(def-class Maildir ()
  (doc "A Maildir++ mail store: folders named by lists of names, each message one file, its flags in its name. A message is an entry (KEY NEW? FLAGS INFO)."
    (example "(Maildir flags (list \"k\" #f (list (lit seen) (lit replied))))" "('replied 'seen)")
    (see folders messages entries info read flag! deliver move! delete! create! uids!))
  (static
    (method folders (self (param root STRING "The Maildir's root directory"))
      (doc "Every folder in the store: (\"INBOX\") first when the root is a Maildir, then each dot folder with a cur/ directory, in the order of their directory names."
        (returns LIST "Folders, each a list of names")
        (sample "(Maildir folders \"/home/me/Maildir\")" "((\"INBOX\") (\"Drafts\") (\"Lists\" \"x-lang\") (\"Sent\"))"))
      (def dots
        (List sort (fn (_ a b) (Str8 <? a b))
          (List filter
            (fn (_ name)
              (if (int= (%byte name 0) 46) (%maildir? (Str8 append root "/" name)) #f))
            (File list-dir root))))
      (def rest-folders (List map (fn (_ name) (%folder-of (str-byte-sub name 1 (int- (str-byte-len name) 1)))) dots))
      (if (%maildir? root) (pair (list "INBOX") rest-folders) rest-folders))

    (method messages (self (param root STRING "The Maildir's root directory") (param folder LIST "A folder"))
      (doc "The folder's messages as entries (KEY NEW? FLAGS INFO), those in new/ and those in cur/, in KEY order: a key begins with its delivery time. Files whose names begin with a dot are left out. INFO has the keys Imap messages gives: (date . TEXT) (from . TEXT) (to . TEXT) (cc . TEXT) (subject . TEXT) (message-id . TEXT) (in-reply-to . TEXT), each the header field as it stands, nil where there is none, read from the header alone; (internal-date . TEXT), the file's mtime as IMAP writes a date-time in UTC; (size . N), the file's size."
        (returns LIST "Entries")
        (sample "(Maildir messages \"/home/me/Maildir\" (list \"INBOX\"))" "((\"1732500000.M1P2.host\" #f (replied seen) ((date . \"Mon, 25 Nov 2024 02:00:00 +0000\") (from . \"ann@example.org\") ...)) ...)"))
      (List map (fn (_ p) (%with-info (first p) (rest p))) (%listing (%folder-dir root folder))))

    (method entries (self (param root STRING "The Maildir's root directory") (param folder LIST "A folder"))
      (doc "The folder's messages as entries (KEY NEW? FLAGS) with no INFO, in KEY order, from the directory listings alone: no file is opened."
        (returns LIST "Entries")
        (sample "(Maildir entries \"/home/me/Maildir\" (list \"INBOX\"))" "((\"1732500000.M1P2.host\" #f (replied seen)) (\"1732500100.M5P2.host\" #t ()))"))
      (List map first (%listing (%folder-dir root folder))))

    (method uids! (self (param root STRING "The Maildir's root directory") (param folder LIST "A folder"))
      (doc "IMAP's UIDs for the folder's messages, kept in its x-lib-mail-uids file: a message keeps the UID it was given, a new one gets the next in KEY order, and one no longer there is dropped; the file is rewritten when that changes anything. A folder with no file, or one in another format, starts over at UID 1 under a new UIDVALIDITY, the time. Answers (UIDVALIDITY NEXT PAIRS): UIDVALIDITY a digit string, NEXT the UID the next message gets, PAIRS (UID . KEY) in UID order. Two programs giving out UIDs in one folder at once can lose each other's; one server a store."
        (returns LIST "(UIDVALIDITY NEXT PAIRS)")
        (sample "(Maildir uids! \"/home/me/Maildir\" (list \"INBOX\"))" "(\"1764200000\" 3 ((1 . \"1732500000.M1P2.host\") (2 . \"1732500100.M5P2.host\")))"))
      (def dir (%folder-dir root folder))
      (def keys (List map (fn (_ p) (first (first p))) (%listing dir)))
      (def old (%read-uids (Str8 str dir "/" %uid-file)))
      (def validity (if (null? old) (Str8 str (Sys now)) (first old)))
      (def pairs (if (null? old) () (%nth old 2)))
      (def merged
        (let go ((ks keys) (ps (List sort (fn (_ a b) (Str8 <? (rest a) (rest b))) pairs)) (kept ()) (fresh ()))
          (match
            ((null? ks) (pair kept (List reverse fresh)))
            ((null? ps) (go (rest ks) ps kept (pair (first ks) fresh)))
            ((str=? (first ks) (rest (first ps))) (go (rest ks) (rest ps) (pair (first ps) kept) fresh))
            ((Str8 <? (rest (first ps)) (first ks)) (go ks (rest ps) kept fresh))
            (#t (go (rest ks) ps kept (pair (first ks) fresh))))))
      (def fresh (rest merged))
      (def given
        (let go ((l fresh) (n (if (null? old) 1 (%nth old 1))) (acc ()))
          (if (null? l) (pair n acc) (go (rest l) (int+ n 1) (pair (pair n (first l)) acc)))))
      (def all (List sort (fn (_ a b) (int< (first a) (first b))) (List append (first merged) (rest given))))
      (when (if (null? old) #t (if (pair? fresh) #t (not (int= (List length (first merged)) (List length pairs)))))
        (%write-uids dir validity (first given) all))
      (list validity (first given) all))

    (method info (self (param root STRING "The Maildir's root directory") (param folder LIST "A folder") (param entry LIST "An entry"))
      (doc "The message's INFO, as messages gives it, for one message found by its KEY."
        (returns ALIST "INFO")
        (sample "(Maildir info root (list \"INBOX\") entry)" "((date . \"Mon, 25 Nov 2024 02:00:00 +0000\") (from . \"ann@example.org\") ... (size . 120))"))
      (def dir (%folder-dir root folder))
      (def at (%locate dir entry))
      (List last (%with-info (list (first entry)) (Str8 str dir "/" (first at) "/" (rest at)))))

    (method delete! (self (param root STRING "The Maildir's root directory") (param folder LIST "A folder") (param entry LIST "An entry"))
      (doc "Remove the message's file, found by its KEY as read and flag! find it: an unlink, for IMAP's EXPUNGE. A key not in the folder raises a label 'value Err."
        (returns LIST "The entry")
        (sample "(Maildir delete! root (list \"INBOX\") entry)" "(\"1732500000.M1P2.host\" #f (seen trashed))"))
      (def dir (%folder-dir root folder))
      (def at (%locate dir entry))
      (File unlink (Str8 append dir "/" (first at) "/" (rest at)))
      entry)

    (method flags (self (param entry LIST "An entry"))
      (doc "The entry's flags, in the order draft flagged passed replied seen trashed."
        (returns LIST "Flag symbols")
        (example "(Maildir flags (list \"k\" #f (list (lit trashed) (lit seen) (lit draft))))" "('draft 'seen 'trashed)"))
      (def flags (first (rest (rest entry))))
      (List map first (List filter (fn (_ f) (List any? (fn (_ s) (eq? s (first f))) flags)) %flag-letters)))

    (method read (self (param root STRING "The Maildir's root directory") (param folder LIST "A folder") (param entry LIST "An entry"))
      (doc "The message's text, as Message parse takes it."
        (returns STRING "The message")
        (sample "(Message parse (Maildir read root (list \"INBOX\") entry))" "(((\"From\" . \"a@b.org\") ...) . \"...\")"))
      (def dir (%folder-dir root folder))
      (def at (%locate dir entry))
      (File read-all (Str8 append dir "/" (first at) "/" (rest at))))

    (method flag! (self (param root STRING "The Maildir's root directory") (param folder LIST "A folder")
                        (param entry LIST "An entry") (param flags LIST "Flag symbols"))
      (doc "Give the message exactly these flags, moving it from new/ to cur/: a rename. Letters for flags this module does not name stay on the file, and the entry's INFO stays on the entry. A symbol that is not one of draft flagged passed replied seen trashed raises a label 'value Err."
        (returns LIST "The message's entry now")
        (sample "(Maildir flag! root (list \"INBOX\") entry (list (lit seen)))" "(\"1732500100.M5P2.host\" #f (seen))"))
      (def dir (%folder-dir root folder))
      (def at (%locate dir entry))
      (def name (Str8 append (first entry) ":2," (%name-letters flags (%letters (rest at)))))
      (def from (Str8 append dir "/" (first at) "/" (rest at)))
      (def to (Str8 append dir "/cur/" name))
      (match ((str=? from to) ()) (#t (File rename from to)))
      (List append (%entry name #f) (rest (rest (rest entry)))))

    (method deliver (self (param root STRING "The Maildir's root directory") (param folder LIST "A folder")
                          (param text STRING "The message")
                          . (param flags LIST "Flag symbols; when given, the message goes into cur/ with them"))
      (doc "Store the message in the folder: written whole into tmp/ under a fresh name (TIME.M<usec>P<pid>.HOST), then renamed into new/, or into cur/ when flags are given (a sent copy, a draft)."
        (returns LIST "The new message's entry")
        (sample "(Maildir deliver root (list \"Sent\") text (list (lit seen)))" "(\"1732500200.M77P9.host\" #f (seen))"))
      (def dir (%folder-dir root folder))
      (def name (%write-tmp dir text))
      (def full (if (null? flags) name (Str8 append name ":2," (%name-letters (first flags) ()))))
      (File rename (Str8 append dir "/tmp/" name) (Str8 append dir (if (null? flags) "/new/" "/cur/") full))
      (%entry full (null? flags)))

    (method move! (self (param root STRING "The Maildir's root directory") (param from LIST "The folder it is in")
                        (param entry LIST "An entry") (param to LIST "The folder it goes to"))
      (doc "Move the message to another folder of the same store, its name, flags and INFO as they are: a rename."
        (returns LIST "The message's entry in its new folder")
        (sample "(Maildir move! root (list \"INBOX\") entry (list \"Trash\"))" "(\"1732500000.M1P2.host\" #f (seen))"))
      (def dir (%folder-dir root from))
      (def at (%locate dir entry))
      (File rename (Str8 append dir "/" (first at) "/" (rest at))
                   (Str8 append (%folder-dir root to) "/" (first at) "/" (rest at)))
      (List append (%entry (rest at) (str=? (first at) "new")) (rest (rest (rest entry)))))

    (method create! (self (param root STRING "The Maildir's root directory") (param folder LIST "A folder"))
      (doc "Make the folder if it is not there: its directory with cur/, new/ and tmp/, mode 0700, and for a dot folder the maildirfolder file Maildir++ marks one with. What is there already is left as it is."
        (returns LIST "The folder")
        (sample "(Maildir create! \"/home/me/Maildir\" (list \"Sent\"))" "(\"Sent\")"))
      (def dir (%folder-dir root folder))
      (List for-each
        (fn (_ d) (unless (eq? (File type d) (lit dir)) (File mkdir d 448)))
        (list dir (Str8 append dir "/cur") (Str8 append dir "/new") (Str8 append dir "/tmp")))
      (def mark (Str8 append dir "/maildirfolder"))
      (match
        ((%inbox? folder) ())
        ((File exists? mark) ())
        (#t (File write-all mark "")))
      folder)))

(doc (provide mail/maildir Maildir)
  "Maildir: a Maildir++ mail store, its folders, messages and flags.")
