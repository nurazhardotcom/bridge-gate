;;;; support.lisp --- Shared helpers and a minimal test harness.
;;;;
;;;; Zero-dependency replacement for Rove: DEFTTEST/TESTING/OK macros plus a
;;;; RUN-TESTS entry point. Test packages (:use) this package and nothing else.

(defpackage #:bridge-gate/test-support
  (:use #:cl)
  (:export #:ht
           #:hget
           #:hhas
           #:signals-p
           #:response
           #:header-value
           #:query-value
           #:deftest
           #:testing
           #:ok
           #:*checks*
           #:*test-failures*
           #:run-tests))

(in-package #:bridge-gate/test-support)

(defvar *checks* 0)
(defvar *failures* '())
(defvar *tests* '())
(defvar *test-failures* 0)

(defmacro deftest (name &body body)
  "Register one test."
  `(push (cons ',name (lambda () ,@body)) *tests*))

(defmacro testing (label &body body)
  "Group assertions under LABEL (documentation only)."
  (declare (ignore label))
  `(progn ,@body))

(defmacro ok (form &optional label)
  "Record one assertion."
  `(progn
     (incf *checks*)
     (unless ,form
       (push (or ,label ',form) *failures*))))

(defun run-tests ()
  "Run every registered test and return the failure count."
  (dolist (test (reverse *tests*))
    (let ((*failures* '())
          (started (get-internal-real-time)))
      (handler-case (funcall (cdr test))
        (error (condition)
          (push (format nil "error: ~A" condition) *failures*)))
      (let ((elapsed (/ (float (- (get-internal-real-time) started) 1d0)
                        internal-time-units-per-second)))
        (cond
          (*failures*
           (incf *test-failures*)
           (format t "FAIL ~A (~,3Fs)~%" (car test) elapsed)
           (dolist (failure (reverse *failures*))
             (format t "  - ~A~%" failure)))
          (t
           (format t "ok   ~A (~,3Fs)~%" (car test) elapsed))))))
  (format t "~%TESTS DONE checks=~A tests=~A failures=~A~%"
          *checks* (length *tests*) *test-failures*)
  *test-failures*)

(defun ht (&rest key-values)
  (apply #'bridge-gate.util:make-map key-values))

(defun hget (map key &optional default)
  (bridge-gate.util:map-get map key default))

(defun hhas (map key)
  (bridge-gate.util:map-has-p map key))

(defun signals-p (thunk &optional (condition-type 'error))
  (handler-case
      (progn (funcall thunk) nil)
    (condition (condition)
      (typep condition condition-type))))

(defun response (status body)
  (list :status status :body body))

(defun header-value (headers name)
  (cdr (assoc name headers :test #'string=)))

(defun query-value (query-params name)
  (cdr (assoc name query-params :test #'string=)))
