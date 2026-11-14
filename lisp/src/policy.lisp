;;;; policy.lisp --- Pure policy evaluation over normalized findings.

(in-package #:bridge-gate.policy)

(defun severity-of (severity)
  (bridge-gate.util:coerce-severity severity))

(defun severity-rank (severity)
  (bridge-gate.util:severity-rank severity))

(defun load-policy (path)
  "Load an EDN policy spec from PATH."
  (let* ((name (bridge-gate.util:to-string path))
         (probe (and (plusp (length name)) (probe-file name))))
    (if probe
        (bridge-gate.edn:read-edn-file probe)
        (bridge-gate.conditions:app-error*
         (format nil "Policy file not found: ~a" name)
         (list :path name)))))

(defun over-budget (rule threshold actual noun)
  (when (> actual threshold)
    (list
     (bridge-gate.util:make-map
      :rule rule
      :threshold threshold
      :actual actual
      :detail (format nil "~a ~a finding(s) exceed max of ~a"
                      actual noun threshold)))))

(defun rule-map (policy)
  (let ((rules (bridge-gate.util:map-get policy :rules)))
    (if (hash-table-p rules)
        rules
        (bridge-gate.util:make-map))))

(defun normalize-findings (findings)
  (map 'vector
       (lambda (finding)
         (unless (hash-table-p finding)
           (bridge-gate.conditions:app-error*
            "Finding must be a JSON object" (list :finding finding)))
         (let ((copy (bridge-gate.util:copy-map finding)))
           (setf (gethash :severity copy)
                 (severity-of (gethash :severity copy)))
           copy))
       (coerce (or findings #()) 'vector)))

(defun blocked-plugin-strings (rules)
  (let ((configured (bridge-gate.util:map-get rules :blocked-plugins)))
    (remove-duplicates
     (mapcar #'bridge-gate.util:to-string
             (coerce (or configured '()) 'list))
     :test #'string=)))

(defun required-fields (rules)
  (let ((configured (bridge-gate.util:map-get rules :required-fields)))
    (if (and (bridge-gate.util:map-has-p rules :required-fields)
             configured)
        (coerce configured 'list)
        '(:host :plugin-id :severity))))

(defun evaluate (findings policy)
  "Evaluate FINDINGS against POLICY.
   Returns a map with :PASSED? (T or :FALSE), :VIOLATIONS, and :SUMMARY."
  (let* ((rules (rule-map policy))
         (normalized (normalize-findings findings))
         (counts (bridge-gate.util:make-map
                  :info 0 :low 0 :medium 0 :high 0 :critical 0))
         (max-criticals (bridge-gate.util:map-get rules :max-criticals 0))
         (max-highs (bridge-gate.util:map-get rules :max-highs 0))
         (max-severity
           (if (bridge-gate.util:map-has-p rules :max-severity)
               (severity-of (bridge-gate.util:map-get rules :max-severity))
               :high))
         (severity-limit (severity-rank max-severity))
         (blocked (blocked-plugin-strings rules))
         (required (required-fields rules))
         (over-severity '())
         (hit-blocked '())
         (missing '()))

    (loop for finding across normalized
          do (let ((severity (gethash :severity finding)))
               (setf (gethash severity counts)
                     (1+ (gethash severity counts)))
               (when (> (severity-rank severity) severity-limit)
                 (push finding over-severity))
               (when (member (bridge-gate.util:to-string
                              (bridge-gate.util:map-get finding :plugin-id))
                             blocked
                             :test #'string=)
                 (push finding hit-blocked))
               (when (some (lambda (field)
                             (bridge-gate.util:blankp
                              (bridge-gate.util:map-get finding field)))
                           required)
                 (push finding missing))))

    (let ((violations '()))
      (dolist (violation (over-budget :max-criticals max-criticals
                                      (gethash :critical counts) "critical"))
        (push violation violations))
      (dolist (violation (over-budget :max-highs max-highs
                                      (gethash :high counts) "high"))
        (push violation violations))
      (when (bridge-gate.util:map-has-p rules :max-mediums)
        (dolist (violation (over-budget :max-mediums
                                        (bridge-gate.util:map-get rules :max-mediums)
                                        (gethash :medium counts)
                                        "medium"))
          (push violation violations)))
      (when over-severity
        (push (bridge-gate.util:make-map
               :rule :max-severity
               :threshold max-severity
               :actual (length over-severity)
               :detail (format nil "~a finding(s) above max severity ~a: ~a"
                               (length over-severity)
                               (bridge-gate.util:keyword-name max-severity)
                               (bridge-gate.util:string-join
                                (remove-duplicates
                                 (mapcar (lambda (finding)
                                           (bridge-gate.util:to-string
                                            (bridge-gate.util:map-get finding :plugin-id)))
                                         over-severity)
                                 :test #'string=)
                                ", ")))
              violations))
      (when hit-blocked
        (let ((plugins (sort (remove-duplicates
                              (mapcar (lambda (finding)
                                        (bridge-gate.util:to-string
                                         (bridge-gate.util:map-get finding :plugin-id)))
                                      hit-blocked)
                              :test #'string=)
                             #'string<)))
          (push (bridge-gate.util:make-map
                 :rule :blocked-plugins
                 :threshold (sort (copy-list blocked) #'string<)
                 :actual plugins
                 :detail (format nil "~a finding(s) match blocked plugins: ~a"
                                 (length hit-blocked)
                                 (bridge-gate.util:string-join plugins ", ")))
                violations)))
      (when missing
        (push (bridge-gate.util:make-map
               :rule :required-fields
               :threshold (map 'vector #'bridge-gate.util:keyword-name required)
               :actual (length missing)
               :detail (format nil "~a finding(s) missing required fields ~a"
                               (length missing)
                               (bridge-gate.util:string-join
                                (mapcar #'bridge-gate.util:keyword-name required)
                                ", ")))
              violations))
      (let ((violations (coerce (nreverse violations) 'vector)))
        (setf (gethash :total counts) (length normalized))
        (bridge-gate.util:make-map
         :passed? (bridge-gate.util:boolean-value (zerop (length violations)))
         :violations violations
         :summary counts)))))

(defun timestamp-now ()
  "Current UTC time as an RFC 3339 string, using only ANSI CL."
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ"
            year month day hour minute second)))

(defun build-block-payload (evaluation meta)
  "Build the structured ServiceNow/Slack block payload for a failed evaluation."
  (let* ((target (bridge-gate.util:to-string
                  (or (bridge-gate.util:map-get meta :target) "unknown")))
         (scan-id (bridge-gate.util:to-string
                   (or (bridge-gate.util:map-get meta :scan-id) "unknown")))
         (policy (bridge-gate.util:to-string
                  (or (bridge-gate.util:map-get meta :policy)
                      "policies/mas_trm.edn")))
         (summary (bridge-gate.util:map-get evaluation :summary))
         (violations (bridge-gate.util:map-get evaluation :violations))
         (count (length violations))
         (headline (format nil "bridge-gate BLOCKED deploy to ~a: ~a policy violation(s)"
                           target count)))
    (bridge-gate.util:make-map
     :event "bridge-gate.policy-violation"
     :tool "bridge-gate"
     :timestamp (timestamp-now)
     :target target
     :scan-id scan-id
     :policy policy
     :passed? :false
     :summary summary
     :violations violations
     :servicenow
     (bridge-gate.util:make-map
      :short_description headline
      :description (format nil "~a~%Scan: ~a~%Policy: ~a~%Summary: ~a"
                           headline scan-id policy
                           (bridge-gate.util:pr-str summary))
      :urgency "1"
      :impact "1"
      :category "Security"
      :assignment_group "Security Operations"
      :cmdb_ci target)
     :slack
     (bridge-gate.util:make-map
      :text headline
      :blocks
      (vector
       (bridge-gate.util:make-map
        :type "header"
        :text (bridge-gate.util:make-map
               :type "plain_text"
               :text "bridge-gate: deploy BLOCKED"))
       (bridge-gate.util:make-map
        :type "section"
        :text (bridge-gate.util:make-map
               :type "mrkdwn"
               :text (format nil "*Target:* ~a~%*Scan:* ~a~%*Policy:* ~a~%*Violations:* ~a"
                             target scan-id policy count)))
       (bridge-gate.util:make-map
        :type "section"
        :text (bridge-gate.util:make-map
               :type "mrkdwn"
               :text (format nil "```~a```"
                             (bridge-gate.util:pr-str violations)))))))))
