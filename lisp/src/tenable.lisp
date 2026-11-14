;;;; tenable.lisp --- Tenable scan triggering, polling, and normalization.

(in-package #:bridge-gate.tenable)

(defun coerce-severity (severity)
  (bridge-gate.util:coerce-severity severity))

(defun default-client (request)
  (bridge-gate.http:default-client request))

(defun parse-json-body (body)
  (cond
    ((null body) (bridge-gate.util:make-map))
    ((hash-table-p body) body)
    ((stringp body)
     (handler-case
         (bridge-gate.json:parse body)
       (error () (bridge-gate.util:make-map))))
    ((or (vectorp body) (consp body)) body)
    (t (bridge-gate.util:make-map))))

(defun path-value (map keys &optional default)
  (let ((current map))
    (dolist (key keys (or current default))
      (setf current (if (hash-table-p current)
                        (gethash key current)
                        nil)))))

(defun check! (response label)
  (unless (member (getf response :status) '(200 201 202))
    (bridge-gate.conditions:app-error*
     (format nil "~a failed" label)
     (list :status (getf response :status)
           :body (parse-json-body (getf response :body)))))
  response)

(defun normalize-finding (target finding)
  (let ((finding (if (hash-table-p finding)
                     finding
                     (bridge-gate.util:make-map))))
    (bridge-gate.util:make-map
     :host (bridge-gate.util:to-string
            (or (gethash "hostname" finding)
                (gethash "host" finding)
                (gethash "ip" finding)
                target))
     :plugin-id (bridge-gate.util:to-string
                 (or (gethash "plugin_id" finding)
                     (gethash "pluginID" finding)
                     (gethash "pluginId" finding)
                     "0"))
     :name (bridge-gate.util:to-string
            (or (gethash "plugin_name" finding)
                (gethash "name" finding)
                "unknown"))
     :severity (coerce-severity
                (or (gethash "severity" finding)
                    (gethash "severity_id" finding)
                    "info"))
     :port (or (gethash "port" finding) 0))))

(defun mock-scan (target)
  "Canned offline payload: 1 high, 2 medium, 0 critical."
  (bridge-gate.util:make-map
   :scan-id "mock-scan-0001"
   :target target
   :status "completed"
   :findings
   (vector
    (bridge-gate.util:make-map :host target :plugin-id "19506"
                               :name "Nessus Scan Information"
                               :severity :info :port 0)
    (bridge-gate.util:make-map :host target :plugin-id "10180"
                               :name "Ping the remote host"
                               :severity :info :port 0)
    (bridge-gate.util:make-map :host target :plugin-id "11219"
                               :name "Nessus SYN scanner"
                               :severity :low :port 22)
    (bridge-gate.util:make-map :host target :plugin-id "51192"
                               :name "SSL Certificate Cannot Be Trusted"
                               :severity :medium :port 443)
    (bridge-gate.util:make-map :host target :plugin-id "57582"
                               :name "SSL Self-Signed Certificate"
                               :severity :medium :port 443)
    (bridge-gate.util:make-map :host target :plugin-id "33850"
                               :name "Unix Operating System Unsupported Version Detection"
                               :severity :high :port 0))))

(defun io-headers (config)
  (list (cons "X-ApiKeys"
              (format nil "accessKey=~a; secretKey=~a"
                      (bridge-gate.util:to-string
                       (bridge-gate.util:map-get config :tenable-access-key))
                      (bridge-gate.util:to-string
                       (bridge-gate.util:map-get config :tenable-secret-key))))
        (cons "Accept" "application/json")
        (cons "Content-Type" "application/json")))

(defun poll-until (config status-function done-states fail-states label)
  "Poll STATUS-FUNCTION until DONE-STATES or attempts run out."
  (let ((max-attempts (or (bridge-gate.util:map-get config :poll-max-attempts) 60))
        (interval (or (bridge-gate.util:map-get config :poll-interval-ms) 10000)))
    (loop for attempt from 0
          do (let ((status (funcall status-function)))
               (cond
                 ((member status done-states :test #'equal)
                  (return status))
                 ((member status fail-states :test #'equal)
                  (bridge-gate.conditions:app-error*
                   (format nil "~a entered failure state: ~a"
                           label (bridge-gate.util:to-string status))
                   (list :status status)))
                 ((>= attempt max-attempts)
                  (bridge-gate.conditions:app-error*
                   (format nil "~a timed out after ~a polls" label max-attempts)
                   (list :last-status status)))
                 (t
                  (sleep (/ interval 1000))))))))

(defun run-io (config client target)
  (when (bridge-gate.util:blankp
         (bridge-gate.util:map-get config :tenable-base-url))
    (bridge-gate.conditions:app-error*
     "Missing required Tenable.io config: :tenable-base-url"
     (bridge-gate.util:make-map)))
  (when (or (bridge-gate.util:blankp
             (bridge-gate.util:map-get config :tenable-access-key))
            (bridge-gate.util:blankp
             (bridge-gate.util:map-get config :tenable-secret-key)))
    (bridge-gate.conditions:app-error*
     "Missing Tenable.io API keys (:tenable-access-key/:tenable-secret-key)"
     (bridge-gate.util:make-map)))
  (let* ((base (bridge-gate.util:strip-trailing-slash
                (bridge-gate.util:to-string
                 (bridge-gate.util:map-get config :tenable-base-url))))
         (headers (io-headers config))
         (configured-scan-id (bridge-gate.util:map-get config :tenable-scan-id))
         (scan-id
           (if (bridge-gate.util:truthy configured-scan-id)
               ;; Launch a pre-configured scan.
               (let ((response
                       (check!
                        (funcall client
                                 (list :method :post
                                       :uri (format nil "~a/api/v3/scans/~a/launch"
                                                    base configured-scan-id)
                                       :headers headers))
                        "Tenable.io scan launch")))
                 (bridge-gate.util:to-string
                  (or (gethash "scan_uuid" (parse-json-body (getf response :body)))
                      configured-scan-id)))
               ;; Create a scan from a template, then launch it.
               (progn
                 (when (bridge-gate.util:blankp
                        (bridge-gate.util:map-get config :tenable-template-uuid))
                   (bridge-gate.conditions:app-error*
                    "Set :tenable-scan-id or :tenable-template-uuid for Tenable.io"
                    (bridge-gate.util:make-map)))
                 (let* ((create-response
                          (check!
                           (funcall client
                                    (list :method :post
                                          :uri (format nil "~a/api/v3/scans" base)
                                          :headers headers
                                          :body (bridge-gate.json:stringify
                                                 (bridge-gate.util:make-map
                                                  :uuid (bridge-gate.util:map-get
                                                         config :tenable-template-uuid)
                                                  :settings
                                                  (bridge-gate.util:make-map
                                                   :name (format nil "bridge-gate ~a" target)
                                                   :text_targets target
                                                   :launch "ON_DEMAND")))))
                           "Tenable.io scan create"))
                        (new-id (bridge-gate.util:to-string
                                 (path-value (parse-json-body
                                              (getf create-response :body))
                                             '("scan" "id")))))
                   (check!
                    (funcall client
                             (list :method :post
                                   :uri (format nil "~a/api/v3/scans/~a/launch"
                                                base new-id)
                                   :headers headers))
                    "Tenable.io scan launch")
                   new-id)))))
    (poll-until
     config
     (lambda ()
       (path-value
        (parse-json-body
         (getf (check! (funcall client
                                (list :method :get
                                      :uri (format nil "~a/api/v3/scans/~a" base scan-id)
                                      :headers headers))
                       "Tenable.io scan status")
               :body))
        '("info" "status") "unknown"))
     '("completed")
     '("aborted" "canceled" "cancelled" "imported")
     "Tenable.io scan")
    (let* ((export-response
             (check!
              (funcall client
                       (list :method :post
                             :uri (format nil "~a/api/v3/scans/~a/export" base scan-id)
                             :headers headers
                             :body (bridge-gate.json:stringify
                                    (bridge-gate.util:make-map :format "json"))))
              "Tenable.io export"))
           (export-id (bridge-gate.util:to-string
                       (gethash "file" (parse-json-body (getf export-response :body))))))
      (poll-until
       config
       (lambda ()
         (path-value
          (parse-json-body
           (getf (check! (funcall client
                                  (list :method :get
                                        :uri (format nil "~a/api/v3/scans/~a/export/~a/status"
                                                     base scan-id export-id)
                                        :headers headers))
                         "Tenable.io export status")
                 :body))
          '("status") "unknown"))
       '("ready")
       '("failure" "error")
       "Tenable.io export")
      (let* ((raw (parse-json-body
                   (getf (check! (funcall client
                                          (list :method :get
                                                :uri (format nil "~a/api/v3/scans/~a/export/~a/download"
                                                             base scan-id export-id)
                                                :headers headers))
                                 "Tenable.io export download")
                         :body)))
             (vulnerabilities
               (cond
                 ((or (vectorp raw)
                      (and (consp raw) (not (hash-table-p raw))))
                  raw)
                 ((hash-table-p raw)
                  (or (gethash "vulnerabilities" raw)
                      (gethash "results" raw)
                      #()))
                 (t #()))))
        (bridge-gate.util:make-map
         :scan-id scan-id
         :target target
         :status "completed"
         :findings (map 'vector
                        (lambda (finding)
                          (normalize-finding target finding))
                        vulnerabilities))))))

(defun run-sc (config client target)
  (when (bridge-gate.util:blankp
         (bridge-gate.util:map-get config :tenable-base-url))
    (bridge-gate.conditions:app-error*
     "Missing required Tenable.sc config: :tenable-base-url"
     (bridge-gate.util:make-map)))
  (let* ((base (bridge-gate.util:strip-trailing-slash
                (bridge-gate.util:to-string
                 (bridge-gate.util:map-get config :tenable-base-url))))
         (configured-token (bridge-gate.util:map-get config :tenable-token))
         (token
           (if (bridge-gate.util:truthy configured-token)
               configured-token
               (progn
                 (when (or (bridge-gate.util:blankp
                            (bridge-gate.util:map-get config :tenable-access-key))
                           (bridge-gate.util:blankp
                            (bridge-gate.util:map-get config :tenable-secret-key)))
                   (bridge-gate.conditions:app-error*
                    "Missing Tenable.sc credentials (:tenable-access-key/:tenable-secret-key or :tenable-token)"
                    (bridge-gate.util:make-map)))
                 (let ((response
                         (check!
                          (funcall client
                                   (list :method :post
                                         :uri (format nil "~a/rest/token" base)
                                         :headers (list (cons "Accept" "application/json")
                                                        (cons "Content-Type" "application/json"))
                                         :body (bridge-gate.json:stringify
                                                (bridge-gate.util:make-map
                                                 :username (bridge-gate.util:map-get
                                                            config :tenable-access-key)
                                                 :password (bridge-gate.util:map-get
                                                            config :tenable-secret-key)))))
                          "Tenable.sc token")))
                   (bridge-gate.util:to-string
                    (path-value (parse-json-body (getf response :body))
                                '("response" "token")))))))
         (headers (list (cons "X-SecurityCenter" (bridge-gate.util:to-string token))
                        (cons "Accept" "application/json")
                        (cons "Content-Type" "application/json"))))
    (when (bridge-gate.util:blankp
           (bridge-gate.util:map-get config :tenable-scan-id))
      (bridge-gate.conditions:app-error*
       "Set :tenable-scan-id (Tenable.sc scan ID) to launch"
       (bridge-gate.util:make-map)))
    (let* ((launch
             (parse-json-body
              (getf (check!
                     (funcall client
                              (list :method :post
                                    :uri (format nil "~a/rest/scan/~a/launch"
                                                 base (bridge-gate.util:map-get
                                                       config :tenable-scan-id))
                                    :headers headers
                                    :body (bridge-gate.json:stringify
                                           (bridge-gate.util:make-map :targets target))))
                     "Tenable.sc scan launch")
                    :body)))
           (result-id (bridge-gate.util:to-string
                       (or (path-value launch '("response" "scanResultID"))
                           (bridge-gate.util:map-get config :tenable-scan-id)))))
      (poll-until
       config
       (lambda ()
         (path-value
          (parse-json-body
           (getf (check! (funcall client
                                  (list :method :get
                                        :uri (format nil "~a/rest/scanResult/~a"
                                                     base result-id)
                                        :headers headers))
                         "Tenable.sc scan status")
                 :body))
          '("response" "status") "unknown"))
       '("Completed")
       '("Error" "Aborted" "Canceled")
       "Tenable.sc scan")
      (let* ((analysis
               (parse-json-body
                (getf (check!
                       (funcall client
                                (list :method :post
                                      :uri (format nil "~a/rest/analysis" base)
                                      :headers headers
                                      :body (bridge-gate.json:stringify
                                             (bridge-gate.util:make-map
                                              :query
                                              (bridge-gate.util:make-map
                                               :name ""
                                               :tool "vulndetails"
                                               :type "vuln"
                                               :filters
                                               (vector
                                                (bridge-gate.util:make-map
                                                 :filterName "scanID"
                                                 :operator "="
                                                 :value result-id)))
                                              :sourceType "cumulative"
                                              :columns #()))))
                       "Tenable.sc analysis")
                      :body)))
             (vulnerabilities (or (path-value analysis '("response" "results")) #())))
        (bridge-gate.util:make-map
         :scan-id result-id
         :target target
         :status "completed"
         :findings (map 'vector
                        (lambda (finding)
                          (normalize-finding target finding))
                        vulnerabilities))))))

(defun run-scan (config target &optional (client #'default-client))
  "Run a scan against TARGET and return a normalized scan map."
  (when (bridge-gate.util:blankp target)
    (bridge-gate.conditions:app-error*
     "Scan target is required (--target)"
     (bridge-gate.util:make-map)))
  (if (bridge-gate.util:truthy (bridge-gate.util:map-get config :mock))
      (mock-scan (bridge-gate.util:to-string target))
      (case (bridge-gate.util:map-get config :tenable-mode)
        (:tenable-io (run-io config client (bridge-gate.util:to-string target)))
        (:tenable-sc (run-sc config client (bridge-gate.util:to-string target)))
        (t
         (bridge-gate.conditions:app-error*
          "Unknown TENABLE_MODE (want :tenable-io or :tenable-sc)"
          (list :mode (bridge-gate.util:map-get config :tenable-mode)))))))
