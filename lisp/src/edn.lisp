;;;; edn.lisp --- Minimal EDN reader for configuration and policy files.

(in-package #:bridge-gate.edn)

(define-condition edn-error (error)
  ((message :initarg :message
            :reader edn-error-message))
  (:report (lambda (condition stream)
             (format stream "~a" (edn-error-message condition)))))

(defun edn-fail (control &rest arguments)
  (error 'edn-error :message (apply #'format nil control arguments)))

(defstruct (reader (:constructor make-reader (string)))
  (string "" :type string)
  (position 0 :type fixnum))

(defun reader-end-p (reader)
  (>= (reader-position reader) (length (reader-string reader))))

(defun peek-character (reader)
  (unless (reader-end-p reader)
    (char (reader-string reader) (reader-position reader))))

(defun next-character (reader)
  (prog1 (peek-character reader)
    (incf (reader-position reader))))

(defun delimiterp (character)
  (or (null character)
      (bridge-gate.util:whitespace-char-p character)
      (char= character #\,)
      (member character '(#\( #\) #\[ #\] #\{ #\} #\" #\;) :test #'char=)))

(defun skip-whitespace (reader)
  (loop
    (when (reader-end-p reader) (return))
    (let ((character (peek-character reader)))
      (cond
        ((or (bridge-gate.util:whitespace-char-p character)
             (char= character #\,))
         (incf (reader-position reader)))
        ((char= character #\;)
         (loop while (and (not (reader-end-p reader))
                          (not (char= (peek-character reader) #\Newline)))
               do (incf (reader-position reader))))
        (t (return))))))

(defun read-token (reader)
  (let ((start (reader-position reader)))
    (loop while (and (not (reader-end-p reader))
                     (not (delimiterp (peek-character reader))))
          do (incf (reader-position reader)))
    (subseq (reader-string reader) start (reader-position reader))))

(defun read-string-literal (reader)
  (next-character reader)                ; opening quote
  (with-output-to-string (out)
    (loop
      (when (reader-end-p reader)
        (edn-fail "Unterminated string literal"))
      (let ((character (next-character reader)))
        (cond
          ((char= character #\")
           (return))
          ((char= character #\\)
           (when (reader-end-p reader)
             (edn-fail "Unterminated string escape"))
           (let ((escape (next-character reader)))
             (case escape
               (#\" (write-char #\" out))
               (#\\ (write-char #\\ out))
               (#\/ (write-char #\/ out))
               (#\n (write-char #\Newline out))
               (#\t (write-char #\Tab out))
               (#\r (write-char #\Return out))
               (#\b (write-char #\Backspace out))
               (#\f (write-char #\Page out))
               (#\u
                (let ((hex (make-string 4)))
                  (dotimes (index 4)
                    (when (reader-end-p reader)
                      (edn-fail "Unterminated unicode escape"))
                    (setf (char hex index) (next-character reader)))
                  (let ((code (ignore-errors (parse-integer hex :radix 16))))
                    (unless (and code (<= 0 code #x10FFFF))
                      (edn-fail "Invalid unicode escape \\u~a" hex))
                    (write-char (code-char code) out))))
               (t (edn-fail "Unsupported string escape \\~a" escape)))))
          (t (write-char character out)))))))

(defun number-token-p (token)
  (and (plusp (length token))
       (let ((start 0)
             (length (length token)))
         (when (member (char token 0) '(#\+ #\-) :test #'char=)
           (incf start))
         (and (< start length)
              (digit-char-p (char token start))))))

(defun parse-number (token)
  (multiple-value-bind (value position)
      (let ((*read-eval* nil))
        (read-from-string token nil nil))
    (if (and value (= position (length token)))
        value
        (edn-fail "Invalid number literal ~s" token))))

(defun read-map (reader)
  (let ((map (bridge-gate.util:make-map)))
    (loop
      (skip-whitespace reader)
      (when (reader-end-p reader)
        (edn-fail "Unterminated map literal"))
      (when (char= (peek-character reader) #\})
        (next-character reader)
        (return map))
      (let ((key (read-value reader)))
        (skip-whitespace reader)
        (when (reader-end-p reader)
          (edn-fail "Unterminated map literal"))
        (when (char= (peek-character reader) #\})
          (edn-fail "Map literal has an odd number of forms"))
        (setf (gethash key map) (read-value reader))))))

(defun read-collection (reader closing-character)
  (let ((items '()))
    (loop
      (skip-whitespace reader)
      (when (reader-end-p reader)
        (edn-fail "Unterminated collection"))
      (when (char= (peek-character reader) closing-character)
        (next-character reader)
        (return (nreverse items)))
      (push (read-value reader) items))))

(defun read-set (reader)
  (read-collection reader #\}))

(defun read-value (reader)
  (skip-whitespace reader)
  (when (reader-end-p reader)
    (edn-fail "Unexpected end of input"))
  (let ((character (peek-character reader)))
    (case character
      (#\{ (next-character reader) (read-map reader))
      (#\[ (next-character reader)
           (coerce (read-collection reader #\]) 'vector))
      (#\( (next-character reader)
           (read-collection reader #\)))
      (#\" (read-string-literal reader))
      (#\:
       (next-character reader)
       (let ((token (read-token reader)))
         (when (zerop (length token))
           (edn-fail "Empty keyword"))
         (intern (string-upcase token) :keyword)))
      (#\#
       (next-character reader)
       (let ((dispatch (peek-character reader)))
         (cond
           ((null dispatch) (edn-fail "Unexpected end of dispatch macro"))
           ((char= dispatch #\{)
            (next-character reader)
            (read-set reader))
           ((char= dispatch #\_)
            (next-character reader)
            (read-value reader)          ; discard one form
            (read-value reader))
           (t (edn-fail "Unsupported dispatch macro #~a" dispatch)))))
      (t
       (let ((token (read-token reader)))
         (cond
           ((string= token "nil") nil)
           ((string= token "true") t)
           ((string= token "false") :false)
           ((number-token-p token) (parse-number token))
           ((zerop (length token))
            (edn-fail "Unexpected character ~s" character))
           (t
            (intern (string-upcase token)
                    (or (find-package :bridge-gate.edn.symbols)
                        (make-package :bridge-gate.edn.symbols))))))))))

(defun read-edn (string)
  "Read the first EDN form from STRING. Returns NIL for empty input."
  (let ((reader (make-reader string)))
    (skip-whitespace reader)
    (if (reader-end-p reader)
        nil
        (read-value reader))))

(defun read-edn-file (path)
  (read-edn (uiop:read-file-string path :external-format :utf-8)))
