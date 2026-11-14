;;;; lisp/build.lisp --- Build a standalone SBCL executable at ../bin/bridge-gate.
;;;;
;;;; Self-contained: registers this directory's own .asd, so this works with
;;;; `sbcl --no-userinit --script lisp/build.lisp` from the repository root
;;;; and with no source-registry setup.
;;;;
;;;; :SAVE-RUNTIME-OPTIONS keeps SBCL's runtime option parser active in the
;;;; saved image, so the runtime does not eat application flags before
;;;; BRIDGE-GATE.CORE:ENTRY sees them, while `--help` still reaches the app.
;;;;
;;;; The build re-executes itself in a child SBCL when XDG_DATA_DIRS contains
;;;; relative entries: ASDF builds its default source registry from that
;;;; variable and rejects values such as "./share/" that sandbox / AppImage
;;;; mount environments inject. Only UIOP (ships with SBCL) is used.

(require :asdf)

(setf asdf:*compile-file-warnings-behaviour* :error)

(defparameter *child-marker* "BRIDGE_GATE_BUILD_CHILD")

(defun relative-path-entry-p (entry)
  (not (and (plusp (length entry)) (char= (char entry 0) #\/))))

(defun xdg-override ()
  "Environment plist for UIOP:RUN-PROGRAM that sanitizes XDG_DATA_DIRS, or NIL
   when the variable is unset or already contains only absolute entries."
  (let* ((raw (uiop:getenv "XDG_DATA_DIRS"))
         (entries (and raw (uiop:split-string raw :separator ":")))
         (absolute (remove-if #'relative-path-entry-p entries)))
    (cond
      ((null raw) nil)
      ((= (length absolute) (length entries)) nil)
      ((plusp (length absolute))
       (list (cons :XDG_DATA_DIRS (format nil "~{~a~^:~}" absolute))))
      (t (list (cons :XDG_DATA_DIRS "/usr/local/share:/usr/share"))))))

(defun lisp-executable ()
  "Absolute path of the SBCL running this build. UIOP:RUN-PROGRAM :ENV
   replaces the child environment, so PATH lookup is not available there."
  (let ((configured (uiop:getenv "LISP")))
    (cond
      ((and configured (uiop:absolute-pathname-p configured)
            (probe-file configured))
       configured)
      ((probe-file sb-ext:*runtime-pathname*)
       (sb-ext:native-namestring sb-ext:*runtime-pathname*))
      (configured configured)
      (t (error "Cannot locate the running SBCL executable")))))

(defun save-image (system-file output)
  (asdf:load-asd system-file)
  (asdf:load-system :bridge-gate)
  (ensure-directories-exist output)
  ;; Resolve the entry point at runtime: under `--script` (and in child
  ;; --eval strings) a literal BRIDGE-GATE.CORE:ENTRY could be read before the
  ;; package exists, so look the symbol up after the system is loaded.
  (let ((toplevel (find-symbol "ENTRY" "BRIDGE-GATE.CORE")))
    (unless (and toplevel (fboundp toplevel))
      (error "bridge-gate.core:entry is not defined"))
    (format t "BUILD: writing ~a~%" (namestring output))
    (sb-ext:save-lisp-and-die output
                              :toplevel toplevel
                              :executable t
                              :compression t
                              :save-runtime-options t)))

(let* ((script (or *load-truename* *default-pathname-defaults*))
       (lisp-directory (uiop:pathname-directory-pathname script))
       (root-directory (uiop:pathname-parent-directory-pathname lisp-directory))
       (system-file (merge-pathnames "bridge-gate.asd" lisp-directory))
       (output (merge-pathnames "bin/bridge-gate" root-directory))
       (override (xdg-override)))
  (cond
    ((null override)
     (save-image system-file output))
    ((uiop:getenv *child-marker*)
     (error "XDG_DATA_DIRS is still malformed after sanitizing; refusing to build"))
    (t
     (uiop:run-program
      (list (lisp-executable) "--no-userinit" "--script" (namestring script))
      :env (cons (cons (intern *child-marker* :keyword) "1") override)
      :output t
      :error-output t))))
