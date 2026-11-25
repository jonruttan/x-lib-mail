; maildir.x -- Maildir: a mail store of one file a message, in Maildir++ folders.
;
; A folder is named by a list of names: ("INBOX") is the root directory itself,
; ("Sent") is ROOT/.Sent and ("Lists" "x-lang") is ROOT/.Lists.x-lang.  Each
; name is written on disk in IMAP's modified UTF-7 (RFC 3501 5.1.3), with "."
; and "/" encoded too, so no name can split into two or leave the root.
;
; A message is an entry (KEY NEW? FLAGS): KEY the file's unique name, NEW? true
; while it sits in new/, FLAGS the symbols draft flagged passed replied seen
; trashed that its name carries, in that order.  The entry gives the file's
; path; when another program has renamed the file since, it is found again by
; its KEY.  Flag letters this module has no symbol for (a server's keywords) are
; kept on the file whenever it is renamed.
(module mail/maildir)

(import x/core/doors char->int int& int+ int- int< int<< int= int>> int| str-byte-len str-byte-ref str-byte-sub)
(import x/codec/utf8 utf8-decode utf8-encode)
(import x/sys/file)
(import x/sys/posix)

(def %fail (fn (_ what data) (Err raise (lit value) (Str8 append "Maildir: " what) data)))

(def %byte (fn (_ s i) (char->int (str-byte-ref s i))))

(def %flag-letters (lit ((draft . 68) (flagged . 70) (passed . 80) (replied . 82) (seen . 83) (trashed . 84))))

; --- Modified UTF-7 ---

(def %b64 "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,")

(def %b64-value
  (fn (_ c)
    (match
      ((if (int< 64 c) (int< c 91) #f) (int- c 65))
      ((if (int< 96 c) (int< c 123) #f) (int- c 71))
      ((if (int< 47 c) (int< c 58) #f) (int+ c 4))
      ((int= c 43) 62)
      ((int= c 44) 63)
      (#t -1))))

; A byte written as itself: printable ASCII but "&", "." and "/".
(def %direct?
  (fn (_ c)
    (match
      ((int< c 32) #f)
      ((int< 126 c) #f)
      (#t (not (if (int= c 38) #t (if (int= c 46) #t (int= c 47))))))))

; The code points as UTF-16 bytes, most significant first.
(def %utf16-bytes
  (fn (_ cps)
    (def unit (fn (_ u acc) (pair (int& u 255) (pair (int>> u 8) acc))))
    (let go ((l cps) (acc ()))
      (match
        ((null? l) (List reverse acc))
        ((int< (first l) 65536) (go (rest l) (unit (first l) acc)))
        (#t (let ((v (int- (first l) 65536)))
              (go (rest l) (unit (int| 56320 (int& v 1023)) (unit (int| 55296 (int>> v 10)) acc)))))))))

; The bytes as base64 in the modified alphabet, unpadded.
(def %b64-encode
  (fn (_ bytes)
    (let go ((l bytes) (bits 0) (n 0) (acc ()))
      (match
        ((int< 5 n)
          (let ((k (int- n 6)))
            (go l (int& bits (int- (int<< 1 k) 1)) k (pair (%byte %b64 (int>> bits k)) acc))))
        ((null? l)
          (List reverse (if (int= n 0) acc (pair (%byte %b64 (int<< bits (int- 6 n))) acc))))
        (#t (go (rest l) (int| (int<< bits 8) (first l)) (int+ n 8) acc))))))

; One folder name as a Maildir++ directory part.
(def %encode-name
  (fn (_ name)
    (def n (str-byte-len name))
    (def cps-from
      (fn (_ i acc)
        (match
          ((int= i n) (pair (List reverse acc) i))
          ((%direct? (%byte name i)) (pair (List reverse acc) i))
          (#t (let ((d (utf8-decode name i))) (cps-from (rest d) (pair (first d) acc)))))))
    (let go ((i 0) (acc ()))
      (match
        ((int= i n) (bytes->str (List reverse acc)))
        ((int= (%byte name i) 38) (go (int+ i 1) (pair 45 (pair 38 acc))))
        ((%direct? (%byte name i)) (go (int+ i 1) (pair (%byte name i) acc)))
        (#t
          (let ((run (cps-from i ())))
            (go (rest run)
                (pair 45 (List append (List reverse (%b64-encode (%utf16-bytes (first run)))) (pair 38 acc))))))))))

; The base64 between "&" and "-" as UTF-8 bytes, or nil when it is not UTF-16.
(def %decode-run
  (fn (_ s from to)
    (def bytes
      (let go ((i from) (bits 0) (n 0) (acc ()))
        (match
          ((int< 7 n)
            (let ((k (int- n 8)))
              (go i (int& bits (int- (int<< 1 k) 1)) k (pair (int>> bits k) acc))))
          ((int= i to) (List reverse acc))
          (#t (let ((v (%b64-value (%byte s i))))
                (if (int< v 0) (lit bad) (go (int+ i 1) (int| (int<< bits 6) v) (int+ n 6) acc)))))))
    (match
      ((eq? bytes (lit bad)) ())
      (#t
        (let go ((l bytes) (acc ()))
          (match
            ((null? l) (List reverse acc))
            ((null? (rest l)) ())
            (#t
              (let ((u (int| (int<< (first l) 8) (first (rest l)))) (r (rest (rest l))))
                (match
                  ((if (int< u 55296) #t (int< 56319 u)) (go r (List append (List reverse (utf8-encode u)) acc)))
                  ((if (null? r) #t (null? (rest r))) ())
                  (#t
                    (let ((lo (int| (int<< (first r) 8) (first (rest r)))))
                      (go (rest (rest r))
                          (List append (List reverse (utf8-encode (int+ 65536 (int| (int<< (int- u 55296) 10) (int- lo 56320))))) acc)))))))))))))

; A directory part back to its folder name; text that is not modified UTF-7 is
; answered as it is written.
(def %decode-name
  (fn (_ s)
    (def n (str-byte-len s))
    (let go ((i 0) (acc ()))
      (match
        ((int= i n) (bytes->str (List reverse acc)))
        ((int= (%byte s i) 38)
          (let ((end (Str8 index-of "-" (str-byte-sub s i (int- n i)))))
            (match
              ((null? end) s)
              ((int= end 1) (go (int+ i 2) (pair 38 acc)))
              (#t (let ((run (%decode-run s (int+ i 1) (int+ i end))))
                    (if (null? run) s (go (int+ i (int+ end 1)) (List append (List reverse run) acc))))))))
        (#t (go (int+ i 1) (pair (%byte s i) acc)))))))

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
  (doc "A Maildir++ mail store: folders named by lists of names, each message one file, its flags in its name. A message is an entry (KEY NEW? FLAGS)."
    (example "(Maildir flags (list \"k\" #f (list (lit seen) (lit replied))))" "('replied 'seen)")
    (see folders messages read flag! deliver move! create!))
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
      (doc "The folder's messages as entries (KEY NEW? FLAGS), those in new/ and those in cur/, in KEY order: a key begins with its delivery time. Files whose names begin with a dot are left out."
        (returns LIST "Entries")
        (sample "(Maildir messages \"/home/me/Maildir\" (list \"INBOX\"))" "((\"1732500000.M1P2.host\" #f (replied seen)) (\"1732500100.M5P2.host\" #t ()))"))
      (def dir (%folder-dir root folder))
      (List sort (fn (_ a b) (Str8 <? (first a) (first b)))
        (List append
          (List map (fn (_ name) (%entry name #t)) (%visible (Str8 append dir "/new")))
          (List map (fn (_ name) (%entry name #f)) (%visible (Str8 append dir "/cur"))))))

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
      (doc "Give the message exactly these flags, moving it from new/ to cur/: a rename. Letters for flags this module does not name stay on the file. A symbol that is not one of draft flagged passed replied seen trashed raises a label 'value Err."
        (returns LIST "The message's entry now")
        (sample "(Maildir flag! root (list \"INBOX\") entry (list (lit seen)))" "(\"1732500100.M5P2.host\" #f (seen))"))
      (def dir (%folder-dir root folder))
      (def at (%locate dir entry))
      (def name (Str8 append (first entry) ":2," (%name-letters flags (%letters (rest at)))))
      (def from (Str8 append dir "/" (first at) "/" (rest at)))
      (def to (Str8 append dir "/cur/" name))
      (match ((str=? from to) ()) (#t (File rename from to)))
      (%entry name #f))

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
      (doc "Move the message to another folder of the same store, its name and flags as they are: a rename."
        (returns LIST "The message's entry in its new folder")
        (sample "(Maildir move! root (list \"INBOX\") entry (list \"Trash\"))" "(\"1732500000.M1P2.host\" #f (seen))"))
      (def dir (%folder-dir root from))
      (def at (%locate dir entry))
      (File rename (Str8 append dir "/" (first at) "/" (rest at))
                   (Str8 append (%folder-dir root to) "/" (first at) "/" (rest at)))
      (%entry (rest at) (str=? (first at) "new")))

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
