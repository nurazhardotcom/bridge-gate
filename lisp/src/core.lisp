;;;; core.lisp --- CLI dispatcher and command implementations.
;;;;
;;;; Commands:
;;;;   bridge-gate cyberark-auth
;;;;   bridge-gate tenable-scan --target <IP>
;;;;   bridge-gate enforce-gate [--policy P] [--input F] [--report R] [--mock]
;;;;
;;;; Exit codes: 0 = gate passed, 1 = policy violation (writes block.json),
;;;;             2 = usage/execution error.

(in-package #:bridge-gate.core)

(defparameter *commands* '("cyberark-auth" "tenable-scan" "enforce-gate"))

(defparameter *cli-spec*
  '((:long "--target" :arg "TARGET" :id :target
     :description "Scan target IP/hostname (tenable-scan)")
    (:long "--policy" :arg "PATH" :id :policy
     :description "Policy spec path (.edn)")
    (:long "--input" :arg "PATH" :id :input
     :description "Findings JSON input file ('-' forces stdin)")
    (:long "--out" :arg "PATH" :id :out
     :description "Where tenable-scan writes findings JSON")
    (:long "--report" :arg "PATH" :id :report
     :description "Where enforce-gate writes block.json on violation")
    (:long "--config" :arg "PATH" :id :config-file
     :description "Optional EDN config file")
    (:long "--notify-webhook" :arg "URL" :id :notify-webhook
     :description "Optional webhook URL to POST the block payload")
    (:long "--mock" :id :mock
     :description "Use built-in mock data (no network)")
    (:short "-h" :long "--help" :id :help
     :description "Show help")))

(defun option-label (spec)
  (let* ((long (getf spec :long))
         (argument (getf spec :arg))
         (text (if argument (format nil "~a ~a" long argument) long)))
    (if (getf spec :short)
        (format nil "  ~a, ~a" (getf spec :short) text)
        (format nil "      ~a" text))))

(defun summarize (&optional (specs *cli-spec*))
  (let ((rows (mapcar (lambda (spec)
                        (cons (option-label spec)
                              (getf spec :description)))
                      specs)))
    (let ((width (reduce #'max rows :key (lambda (row) (length (car row))))))
      (bridge-gate.util:string-join
       (mapcar (lambda (row)
                 (format nil "~a~a~a"
                         (car row)
                         (make-string (+ 2 (- width (length (car row))))
                                      :initial-element #\Space)
                         (cdr row)))
               rows)
       (string #\Newline)))))

(defun usage (&optional (summary (summarize)))
  (bridge-gate.util:string-join
   (list "bridge-gate - Enterprise Compliance-as-Code Engine"
         ""
         "Usage: bridge-gate <command> [options]"
         ""
         "Commands:"
         "  cyberark-auth    Fetch short-lived credential via CyberArk"
         "  tenable-scan     Trigger scan for --target and save findings JSON"
         "  enforce-gate     Evaluate findings against policy (exit 0/1/2)"
         ""
         "Options:"
         summary
         ""
         "Exit codes: 0 gate passed - 1 policy violation - 2 usage/execution error"
         "Examples:"
         "  bridge-gate cyberark-auth --mock"
         "  bridge-gate tenable-scan --target 10.10.50.12 --mock"
         "  bridge-gate enforce-gate --policy policies/mas_trm.edn --mock")
   (string #\Newline)))

;;; ---------------------------------------------------------------------------
;;; Output helpers
;;; ---------------------------------------------------------------------------

(defun errln (control &rest arguments)
  (apply #'format *error-output* control arguments)
  (terpri *error-output*)
  (finish-output *error-output*))

(defun println (string)
  (write-string string *standard-output*)
  (terpri *standard-output*)
  (finish-output *standard-output*))

(defun spit-json (path data)
  (let ((pathname (pathname path)))
    (ensure-directories-exist pathname)
    (with-open-file (stream pathname
                            :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create
                            :external-format :utf-8)
      (bridge-gate.json:write-pretty data stream))))

(defun read-stream-string (stream)
  (with-output-to-string (out)
    (loop for character = (read-char stream nil nil)
          while character
          do (write-char character out))))

(defun stdin-available-p ()
  (handler-case
      (and (listen *standard-input*) t)
    (error () nil)))

;;; ---------------------------------------------------------------------------
;;; CLI parsing (small hand-rolled option parser)
;;; ---------------------------------------------------------------------------

(defun find-long-option (name)
  (find name *cli-spec*
        :test #'string=
        :key (lambda (spec) (getf spec :long))))

(defun set-option (options id value)
  (setf (gethash id options) value))

(defun parse-long-option (options argument arguments index count)
  "Parse one --long option. Returns (values next-index error-or-nil)."
  (let* ((equals (position #\= argument))
         (name (if equals (subseq argument 0 equals) argument))
         (inline-value (and equals (subseq argument (1+ equals))))
         (spec (find-long-option name)))
    (cond
      ((null spec)
       (values (1+ index)
               (format nil "Unknown option: \"~a\"" name)))
      ((getf spec :arg)
       (cond
         (equals
          (set-option options (getf spec :id) inline-value)
          (values (1+ index) nil))
         ((< (1+ index) count)
          (set-option options (getf spec :id) (aref arguments (1+ index)))
          (values (+ index 2) nil))
         (t
          (values (1+ index)
                  (format nil "Missing required argument for \"~a ~a\""
                          name (getf spec :arg))))))
      (equals
       (values (1+ index)
               (format nil "Option \"~a\" does not take an argument." name)))
      (t
       (set-option options (getf spec :id) t)
       (values (1+ index) nil)))))

(defun parse-short-options (options argument)
  "Parse a cluster of short options. Returns an error string or NIL."
  (loop for position from 1 below (length argument)
        for character = (char argument position)
        do (cond
             ((char= character #\h)
              (set-option options :help t))
             (t
              (return (format nil "Unknown option: \"-~a\"" character))))
        finally (return nil)))

(defun parse-cli (arguments)
  "Parse ARGUMENTS (a vector). Returns (values options errors summary)."
  (let ((options (bridge-gate.util:make-map :help :false))
        (errors '())
        (positional '())
        (index 0)
        (count (length arguments)))
    (loop while (< index count)
          do (let ((argument (aref arguments index)))
               (cond
                 ((string= argument "--")
                  (loop for rest from (1+ index) below count
                        do (push (aref arguments rest) positional))
                  (setf index count))
                 ((and (> (length argument) 2)
                       (string= argument "--" :end1 2))
                  (multiple-value-bind (next-index error)
                      (parse-long-option options argument arguments index count)
                    (setf index next-index)
                    (when error (push error errors))))
                 ((and (> (length argument) 1)
                       (char= (char argument 0) #\-))
                  (let ((error (parse-short-options options argument)))
                    (incf index)
                    (when error (push error errors))))
                 (t
                  (push argument positional)
                  (incf index)))))
    (values options (nreverse errors) (summarize))))

(defun split-command (arguments)
  "Split ARGUMENTS into (values subcommand option-arguments)."
  (if (or (null arguments)
          (bridge-gate.util:starts-with-p "-" (first arguments)))
      (values nil arguments)
      (values (first arguments) (rest arguments))))

;;; ---------------------------------------------------------------------------
;;; Findings input
;;; ---------------------------------------------------------------------------

(defun sequence-value-p (value)
  (and (not (stringp value))
       (or (vectorp value)
           (and (consp value) (not (hash-table-p value))))))

(defun read-findings (config)
  (let* ((explicit (bridge-gate.util:map-get config :input))
         (path (bridge-gate.util:to-string
                (or explicit (bridge-gate.util:map-get config :findings)))))
    (cond
      ((and (not (string= path "-"))
            (plusp (length path))
            (probe-file path))
       (bridge-gate.json:parse-file path :keywordize t))
      ((or (string= path "-")
           (equal explicit "-")
           (stdin-available-p))
       (bridge-gate.json:parse (read-stream-string *standard-input*)
                               :keywordize t))
      (t
       (bridge-gate.conditions:app-error*
        (format nil "No findings input: file not found (~a) and stdin is empty. Run tenable-scan first or pipe findings via stdin / --input -."
                path)
        (list :path path))))))

(defun extract-findings (raw)
  "Accept a full scan map (:findings [...]) or a bare findings vector."
  (cond
    ((sequence-value-p raw)
     (coerce raw 'vector))
    ((hash-table-p raw)
     (cond
       ((sequence-value-p (gethash :findings raw))
        (coerce (gethash :findings raw) 'vector))
       ((sequence-value-p (gethash "findings" raw))
        (coerce (gethash "findings" raw) 'vector))
       (t
        (bridge-gate.conditions:app-error*
         "Findings input must be a scan map with :findings or a vector"
         (bridge-gate.util:make-map)))))
    (t
     (bridge-gate.conditions:app-error*
      "Findings input must be a scan map with :findings or a vector"
      (bridge-gate.util:make-map)))))

(defun raw-field (raw key)
  (if (hash-table-p raw)
      (gethash key raw)
      nil))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

(defun cmd-cyberark-auth (config)
  (let ((credential (bridge-gate.cyberark:fetch-credential config)))
    (println (bridge-gate.json:stringify credential :pretty t))
    0))

(defun cmd-tenable-scan (config)
  (when (bridge-gate.util:blankp (bridge-gate.util:map-get config :target))
    (bridge-gate.conditions:app-error*
     "tenable-scan requires --target <IP/hostname>"
     (bridge-gate.util:make-map)))
  (let* ((target (bridge-gate.util:map-get config :target))
         (scan (bridge-gate.tenable:run-scan config target))
         (out (bridge-gate.util:to-string
               (or (bridge-gate.util:map-get config :out)
                   (bridge-gate.util:map-get config :findings))))
         (findings (bridge-gate.util:map-get scan :findings))
         (counts (bridge-gate.util:make-map)))
    (loop for finding across findings
          do (let ((severity (bridge-gate.util:map-get finding :severity)))
               (setf (gethash severity counts)
                     (1+ (gethash severity counts 0)))))
    (spit-json out scan)
    (println
     (bridge-gate.json:stringify
      (bridge-gate.util:make-map
       :scan-id (bridge-gate.util:map-get scan :scan-id)
       :target (bridge-gate.util:map-get scan :target)
       :status (bridge-gate.util:map-get scan :status)
       :counts counts
       :total (length findings)
       :out out)
      :pretty t))
    0))

(defun notify-webhook! (url payload)
  (handler-case
      (let ((response
              (bridge-gate.http:default-client
               (list :method :post
                     :uri (bridge-gate.util:to-string url)
                     :headers (list (cons "Content-Type" "application/json"))
                     :body (bridge-gate.json:stringify
                            (bridge-gate.util:map-get payload :slack))))))
        (errln "notify-webhook: HTTP ~a" (getf response :status)))
    (error (condition)
      (errln "notify-webhook failed (non-fatal): ~a" condition))))

(defun cmd-enforce-gate (config)
  (let* ((policy (bridge-gate.policy:load-policy
                  (bridge-gate.util:map-get config :policy)))
         (raw (read-findings config))
         (findings (extract-findings raw))
         (result (bridge-gate.policy:evaluate findings policy))
         (meta (bridge-gate.util:make-map
                :target (or (bridge-gate.util:map-get config :target)
                            (raw-field raw :target)
                            (raw-field raw "target"))
                :scan-id (or (raw-field raw :scan-id)
                             (raw-field raw "scan_id")
                             (raw-field raw "scan-id"))
                :policy (bridge-gate.util:map-get config :policy))))
    (if (bridge-gate.util:truthy (bridge-gate.util:map-get result :passed?))
        (progn
          (setf (gethash :gate result) "PASS")
          (println (bridge-gate.json:stringify result :pretty t))
          0)
        (let* ((payload (bridge-gate.policy:build-block-payload result meta))
               (report (bridge-gate.util:to-string
                        (bridge-gate.util:map-get config :report))))
          (spit-json report payload)
          (when (bridge-gate.util:truthy
                 (bridge-gate.util:map-get config :notify-webhook))
            (notify-webhook! (bridge-gate.util:map-get config :notify-webhook)
                             payload))
          (setf (gethash :gate result) "BLOCK")
          (println (bridge-gate.json:stringify result :pretty t))
          (errln "GATE BLOCKED: ~a violation(s). Report written to ~a"
                 (length (bridge-gate.util:map-get result :violations))
                 report)
          1))))

;;; ---------------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------------

(defun main (&optional (arguments '()))
  (multiple-value-bind (command option-arguments)
      (split-command arguments)
    (multiple-value-bind (options errors summary)
        (parse-cli (coerce option-arguments 'vector))
      (handler-case
          (cond
            (errors
             (dolist (error errors)
               (errln "Error: ~a" error))
             (errln "~a" (usage summary))
             2)
            ((bridge-gate.util:truthy (bridge-gate.util:map-get options :help))
             (println (usage summary))
             0)
            ((null command)
             (errln "Error: missing command.")
             (errln "~a" (usage summary))
             2)
            ((not (member command *commands* :test #'string=))
             (errln "Unknown command: ~a" command)
             (errln "~a" (usage summary))
             2)
            (t
             (let ((config (bridge-gate.config:load-config options)))
               (cond
                 ((string= command "cyberark-auth")
                  (cmd-cyberark-auth config))
                 ((string= command "tenable-scan")
                  (cmd-tenable-scan config))
                 ((string= command "enforce-gate")
                  (cmd-enforce-gate config))
                 (t 2)))))
        (bridge-gate.conditions:app-error (condition)
          (errln "Error: ~a" (bridge-gate.conditions:app-error-message condition))
          (when (bridge-gate.conditions:app-error-detail condition)
            (errln "Detail: ~a"
                   (bridge-gate.util:pr-str
                    (bridge-gate.conditions:app-error-detail condition))))
          2)
        (error (condition)
          (errln "Error: ~a" condition)
          2)))))

(defun entry ()
  (uiop:quit (main (uiop:command-line-arguments)) t))
