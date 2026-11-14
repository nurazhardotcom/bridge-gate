;;;; conditions.lisp --- Application-level conditions.

(in-package #:bridge-gate.conditions)

(define-condition app-error (error)
  ((message :initarg :message
            :reader app-error-message)
   (detail :initarg :detail
           :initform nil
           :reader app-error-detail))
  (:report (lambda (condition stream)
             (format stream "~a" (app-error-message condition)))))

(defun app-error* (message &optional detail)
  "Signal an application error carrying MESSAGE and an optional DETAIL plist."
  (error 'app-error :message message :detail detail))
