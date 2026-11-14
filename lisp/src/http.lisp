;;;; http.lisp --- Minimal HTTP client over a curl subprocess.
;;;;
;;;; SBCL ships no TLS stack, so live HTTP/HTTPS requests go through the
;;;; ubiquitous `curl` binary (argv based, never a shell string). Every unit
;;;; test injects a mock client, so this path is never exercised offline;
;;;; live failures are fail-closed application errors (exit 2 upstream).

(in-package #:bridge-gate.http)

(defun header-alist (headers)
  (cond
    ((null headers) '())
    ((hash-table-p headers)
     (let ((entries '()))
       (maphash (lambda (name value)
                  (push (cons (bridge-gate.util:to-string name)
                              (bridge-gate.util:to-string value))
                        entries))
                headers)
       (nreverse entries)))
    ((and (consp headers) (consp (car headers)))
     (mapcar (lambda (entry)
               (cons (bridge-gate.util:to-string (car entry))
                     (bridge-gate.util:to-string (cdr entry))))
             headers))
    (t '())))

(defun query-alist (query-params)
  (cond
    ((null query-params) '())
    ((hash-table-p query-params)
     (sort (loop for key being the hash-keys of query-params
                   using (hash-value value)
                 collect (cons (bridge-gate.util:to-string key)
                               (bridge-gate.util:to-string value)))
           #'string< :key #'car))
    ((and (consp query-params) (consp (car query-params)))
     query-params)
    (t '())))

(defun percent-encode (string)
  "Percent-encode STRING for a URL query component (RFC 3986)."
  (with-output-to-string (out)
    (loop for character across string
          do (if (or (alphanumericp character)
                     (find character "-_.~" :test #'char=))
                 (write-char character out)
                 (format out "%~2,'0X" (char-code character))))))

(defun encode-query (pairs)
  (bridge-gate.util:string-join
   (mapcar (lambda (pair)
             (format nil "~a=~a"
                     (percent-encode (car pair))
                     (percent-encode (cdr pair))))
           pairs)
   "&"))

(defun request-url (uri query-params)
  (let ((query (query-alist query-params)))
    (if (null query)
        uri
        (format nil "~a?~a" uri (encode-query query)))))

(defun response-headers-map (headers)
  "Convert an alist of (NAME . VALUE) header pairs to a string-keyed map."
  (let ((map (make-hash-table :test 'equal)))
    (dolist (entry headers map)
      (when (consp entry)
        (setf (gethash (bridge-gate.util:to-string (car entry)) map)
              (bridge-gate.util:to-string (cdr entry)))))))

(defun unique-temp-path (tag)
  (merge-pathnames (format nil "bridge-gate-~a-~a-~a.tmp"
                           tag (get-universal-time) (random 1000000))
                   (uiop:temporary-directory)))

(defun parse-status-line (line)
  "Parse 'HTTP/1.1 200 OK' (or 'HTTP/2 200') to its numeric status."
  (let ((space (position #\Space line)))
    (when space
      (let* ((rest (string-trim " " (subseq line (1+ space))))
             (end (position #\Space rest)))
        (ignore-errors
         (parse-integer rest :start 0 :end (or end (length rest))))))))

(defun parse-header-dump (path)
  "Parse a curl -D header dump. Returns (values status headers-map)."
  (let ((map (make-hash-table :test 'equal))
        (status nil))
    (with-open-file (stream path :direction :input
                                  :external-format :latin-1
                                  :if-does-not-exist nil)
      (when (null stream)
        (error "curl wrote no header dump"))
      (setf status (parse-status-line (or (read-line stream nil "") "")))
      (loop for line = (read-line stream nil nil)
            while line
            for trimmed = (bridge-gate.util:trim line)
            while (plusp (length trimmed))
            do (let ((colon (position #\: trimmed)))
                 (when colon
                   (setf (gethash (bridge-gate.util:trim (subseq trimmed 0 colon)) map)
                         (bridge-gate.util:trim (subseq trimmed (1+ colon))))))))
    (unless (and (integerp status) (<= 100 status 599))
      (error "curl returned an unparsable HTTP status"))
    (values status map)))

(defun read-body-file (path)
  (if (and path (probe-file path))
      (uiop:read-file-string path :external-format :utf-8)
      ""))

(defun default-client (request)
  "Perform REQUEST (a plist with :METHOD :URI :HEADERS :QUERY-PARAMS :BODY)
   and return (:STATUS n :BODY string :HEADERS map). HTTP error statuses are
   returned rather than signaled, mirroring the original :throw false behavior."
  (let* ((uri (bridge-gate.util:to-string (getf request :uri)))
         (method (string-upcase
                  (bridge-gate.util:to-string (or (getf request :method) :get))))
         (url (request-url uri (getf request :query-params)))
         (headers (header-alist (getf request :headers)))
         (content (getf request :body))
         (body-file (unique-temp-path "body"))
         (head-file (unique-temp-path "head")))
    (unwind-protect
         (handler-case
             (let ((arguments (append (list "-sS" "-X" method
                                            "-o" (namestring body-file)
                                            "-D" (namestring head-file))
                                      (loop for (name . value) in headers
                                            append (list "-H" (format nil "~a: ~a" name value)))
                                      (when content (list "--data-binary" "@-"))
                                      (list url))))
               (multiple-value-bind (output error-output exit-code)
                   (uiop:run-program (cons "curl" arguments)
                                      :output :string
                                      :error-output :string
                                      ;; UIOP treats a string :INPUT as a
                                      ;; pathname; wrap the request body in a
                                      ;; stream so it reaches curl's stdin.
                                      :input (when content
                                               (make-string-input-stream
                                                (bridge-gate.util:to-string content)))
                                      :ignore-error-status t)
                 (declare (ignore output))
                 (cond
                   ((zerop exit-code)
                    (multiple-value-bind (status header-map)
                        (parse-header-dump head-file)
                      (list :status status
                            :body (read-body-file body-file)
                            :headers header-map)))
                   (t
                    (bridge-gate.conditions:app-error*
                     (format nil "HTTP request failed (curl exit ~a): ~a"
                             exit-code (bridge-gate.util:trim error-output))
                     (list :url url :exit exit-code))))))
           (bridge-gate.conditions:app-error (condition)
             (error condition))
           (error (condition)
             (bridge-gate.conditions:app-error*
              (format nil "HTTP request failed: ~a" condition)
              (list :url url))))
      (ignore-errors (delete-file body-file))
      (ignore-errors (delete-file head-file)))))
