;;;; util.lisp --- Shared string, map, severity, and EDN-printing helpers.

(in-package #:bridge-gate.util)

;;; ---------------------------------------------------------------------------
;;; Strings
;;; ---------------------------------------------------------------------------

(defun whitespace-char-p (character)
  (member character '(#\Space #\Tab #\Newline #\Return #\Page)
          :test #'char=))

(defun trim (string)
  (string-trim '(#\Space #\Tab #\Newline #\Return #\Page) string))

(defun blankp (value)
  "Blank predicate: NIL, the empty string, or whitespace-only text."
  (or (null value)
      (let ((string (if (stringp value) value (princ-to-string value))))
        (every #'whitespace-char-p string))))

(defun to-string (value)
  "Coerce value to a string for the values this program handles."
  (cond
    ((null value) "")
    ((stringp value) value)
    ((eq value t) "true")
    ((eq value :false) "false")
    ((keywordp value)
     (format nil ":~a" (string-downcase (symbol-name value))))
    ((characterp value) (string value))
    (t (princ-to-string value))))

(defun keyword-name (keyword)
  (string-downcase (symbol-name keyword)))

(defun string-join (strings &optional (separator ""))
  (with-output-to-string (out)
    (let ((first t))
      (dolist (string strings)
        (if first
            (setf first nil)
            (write-string separator out))
        (write-string (to-string string) out)))))

(defun starts-with-p (prefix string)
  (and (stringp prefix)
       (stringp string)
       (<= (length prefix) (length string))
       (string= prefix string :end2 (length prefix))))

(defun ends-with-p (suffix string)
  (and (stringp suffix)
       (stringp string)
       (<= (length suffix) (length string))
       (string= suffix string :start2 (- (length string) (length suffix)))))

(defun replace-all (old new string)
  (if (zerop (length old))
      string
      (with-output-to-string (out)
        (loop with start = 0
              for position = (search old string :start2 start)
              while position
              do (write-string string out :start start :end position)
                 (write-string new out)
                 (setf start (+ position (length old)))
              finally (write-string string out :start start)))))

(defun strip-trailing-slash (string)
  "Remove at most one trailing slash, matching #\"/$\" replacement."
  (if (and (plusp (length string))
           (char= (char string (1- (length string))) #\/))
      (subseq string 0 (1- (length string)))
      string))

(defun strip-leading-slashes (string)
  (string-left-trim "/" string))

;;; ---------------------------------------------------------------------------
;;; Booleans
;;; ---------------------------------------------------------------------------

(defun truthy (value)
  "Truthiness over our value model: NIL and :FALSE are false."
  (and value (not (eq value :false))))

(defun boolean-value (predicate)
  "Return T or :FALSE explicitly so JSON never has to guess."
  (if predicate t :false))

;;; ---------------------------------------------------------------------------
;;; Maps (equal hash tables)
;;; ---------------------------------------------------------------------------

(defun make-map (&rest key-values)
  (let ((map (make-hash-table :test 'equal
                              :size (max 1 (floor (length key-values) 2)))))
    (loop for (key value) on key-values by #'cddr
          do (setf (gethash key map) value))
    map))

(defun map-get (map key &optional default)
  (if (hash-table-p map)
      (gethash key map default)
      default))

(defun map-has-p (map key)
  (and (hash-table-p map)
       (nth-value 1 (gethash key map))))

(defun map-set (map key value)
  (setf (gethash key map) value)
  map)

(defun copy-map (map)
  (let ((copy (make-hash-table :test (hash-table-test map)
                               :size (max 1 (hash-table-size map)))))
    (maphash (lambda (key value)
               (setf (gethash key copy) value))
             map)
    copy))

(defun map-keys (map)
  (let ((keys '()))
    (maphash (lambda (key value)
               (declare (ignore value))
               (push key keys))
             map)
    (nreverse keys)))

(defun map-values (map)
  (let ((values '()))
    (maphash (lambda (key value)
               (declare (ignore key))
               (push value values))
             map)
    (nreverse values)))

(defun map-remove (map key)
  (remhash key map)
  map)

(defun merge-maps (target source)
  (when (hash-table-p source)
    (maphash (lambda (key value)
               (setf (gethash key target) value))
             source))
  target)

(defun alist->map (alist)
  (let ((map (make-hash-table :test 'equal :size (max 1 (length alist)))))
    (dolist (entry alist map)
      (cond
        ((consp entry)
         (setf (gethash (car entry) map) (cdr entry)))
        (t
         (setf (gethash entry map) t))))))

;;; ---------------------------------------------------------------------------
;;; Severity coercion (shared by the policy engine and Tenable normalization)
;;; ---------------------------------------------------------------------------

(defparameter *severity-order*
  '(:info :low :medium :high :critical))

(defun severity-key-p (value)
  (and (keywordp value) (member value *severity-order* :test #'eq)))

(defun severity-rank (severity)
  (let ((position (position severity *severity-order* :test #'eq)))
    (or position 0)))

(defun coerce-severity (value)
  "Coerce keyword/string/number severity to a keyword.
   Fail-closed: anything unrecognized becomes :CRITICAL."
  (cond
    ((keywordp value)
     (if (severity-key-p value) value :critical))
    ((numberp value)
     (case (truncate value)
       (0 :info)
       (1 :low)
       (2 :medium)
       (3 :high)
       (4 :critical)
       (otherwise :critical)))
    ((stringp value)
     (let ((text (string-downcase (trim value))))
       (cond
         ((member text '("0" "info" "none") :test #'string=) :info)
         ((member text '("1" "low") :test #'string=) :low)
         ((member text '("2" "medium" "med") :test #'string=) :medium)
         ((member text '("3" "high") :test #'string=) :high)
         ((member text '("4" "critical" "crit") :test #'string=) :critical)
         (t :critical))))
    (t :critical)))

;;; ---------------------------------------------------------------------------
;;; EDN pr-str (used inside human-readable payload strings)
;;; ---------------------------------------------------------------------------

(defun pr-str (value)
  (with-output-to-string (out)
    (print-edn value out)))

(defun print-edn-string (string out)
  (write-char #\" out)
  (loop for character across string
        do (case character
             (#\" (write-string "\\\"" out))
             (#\\ (write-string "\\\\" out))
             (#\Newline (write-string "\\n" out))
             (#\Tab (write-string "\\t" out))
             (#\Return (write-string "\\r" out))
             (#\Page (write-string "\\f" out))
             (#\Backspace (write-string "\\b" out))
             (t (write-char character out))))
  (write-char #\" out))

(defun print-edn (value out)
  (cond
    ((null value) (write-string "nil" out))
    ((eq value t) (write-string "true" out))
    ((eq value :false) (write-string "false" out))
    ((keywordp value)
     (format out ":~a" (keyword-name value)))
    ((stringp value) (print-edn-string value out))
    ((integerp value) (format out "~d" value))
    ((rationalp value) (format out "~a" value))
    ((floatp value) (format out "~f" value))
    ((characterp value) (format out "#\\~a" value))
    ((hash-table-p value)
     (write-char #\{ out)
     (let ((keys (sort (map-keys value)
                       #'string<
                       :key (lambda (key) (pr-str key)))))
       (loop for key in keys
             for first = t then nil
             do (unless first (write-string ", " out))
                (print-edn key out)
                (write-char #\Space out)
                (print-edn (gethash key value) out)))
     (write-char #\} out))
    ((vectorp value)
     (write-char #\[ out)
     (loop for index from 0 below (length value)
           do (when (plusp index) (write-char #\Space out))
              (print-edn (aref value index) out))
     (write-char #\] out))
    ((consp value)
     (write-char #\( out)
     (loop for item in value
           for first = t then nil
           do (unless first (write-char #\Space out))
              (print-edn item out))
     (write-char #\) out))
    ((symbolp value)
     (write-string (string-downcase (symbol-name value)) out))
    (t (princ value out))))
