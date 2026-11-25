; # x-lib-mail -- mail on x-lang
;
; ## tests/harness.x -- what the spec harness adds to the dialect
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The bundle kit's generator writes tests/lib/harness.gen.x: the dialect
; bundle.xon declares, the bundle's lib/ on the import path, then this
; file.  Each spec imports the modules it tests; what is added here is the
; fresh directory under /tmp the Maildir specs work in and remove after.

(import x/sys/file)

; A new empty directory: its path.
(def %spec-root
  (fn (_)
    (def t (File temp "/tmp/x-lib-mail-"))
    (File close (first t))
    (File unlink (rest t))
    (File mkdir (rest t) 448)
    (rest t)))

; Every directory and file under root, relative to it, in byte order; a
; directory ends with "/".
(def %spec-tree
  (fn (_ root)
    (def walk
      (fn (self rel acc)
        (List fold
          (fn (_ found name)
            (def r (if (str=? rel "") name (Str8 append rel "/" name)))
            (if (eq? (File ltype (Str8 append root "/" r)) (lit dir))
              (self r (pair (Str8 append r "/") found))
              (pair r found)))
          acc
          (File list-dir (if (str=? rel "") root (Str8 append root "/" rel))))))
    (List sort (fn (_ a b) (Str8 <? a b)) (walk "" ()))))

; Remove root and everything under it.
(def %spec-rm
  (fn (self path)
    (match
      ((eq? (File ltype path) (lit dir))
        (do (List for-each (fn (_ name) (self (Str8 append path "/" name))) (File list-dir path))
            (File rmdir path)))
      (#t (File unlink path)))))
