;;;; config.lisp --- Configuration loading.
;;;;
;;;; Precedence (lowest to highest): defaults < config.edn file < env vars < CLI opts.

(in-package #:bridge-gate.config)

(defun defaults ()
  (bridge-gate.util:make-map
   :cyberark-mode :ccp
   :cyberark-base-url nil
   :cyberark-app-id nil
   :cyberark-safe nil
   :cyberark-object nil
   :conjur-appliance-url nil
   :conjur-account "default"
   :conjur-authn-login nil
   :conjur-api-key nil
   :conjur-secret-var nil
   :tenable-mode :tenable-io
   :tenable-base-url nil
   :tenable-access-key nil
   :tenable-secret-key nil
   :tenable-scan-id nil
   :tenable-template-uuid nil
   :tenable-repo-id nil
   :poll-interval-ms 10000
   :poll-max-attempts 60
   :policy "policies/mas_trm.edn"
   :findings ".bridge/findings.json"
   :report ".bridge/block.json"
   :out nil
   :input nil
   :target nil
   :notify-webhook nil
   :mock :false
   :config-file "config.edn"))

(defun getenv (name)
  (let ((value (uiop:getenv name)))
    (unless (bridge-gate.util:blankp value)
      value)))

(defun truthy-string-p (string)
  (member (string-downcase (bridge-gate.util:trim (bridge-gate.util:to-string string)))
          '("1" "true" "yes" "y" "on")
          :test #'string=))

(defparameter *environment*
  '(("CYBERARK_MODE" :cyberark-mode :mode)
    ("CYBERARK_BASE_URL" :cyberark-base-url :string)
    ("CYBERARK_APP_ID" :cyberark-app-id :string)
    ("CYBERARK_SAFE" :cyberark-safe :string)
    ("CYBERARK_OBJECT" :cyberark-object :string)
    ("CONJUR_APPLIANCE_URL" :conjur-appliance-url :string)
    ("CONJUR_ACCOUNT" :conjur-account :string)
    ("CONJUR_AUTHN_LOGIN" :conjur-authn-login :string)
    ("CONJUR_API_KEY" :conjur-api-key :string)
    ("CONJUR_SECRET_VAR" :conjur-secret-var :string)
    ("TENABLE_MODE" :tenable-mode :tenable-mode)
    ("TENABLE_BASE_URL" :tenable-base-url :string)
    ("TENABLE_ACCESS_KEY" :tenable-access-key :string)
    ("TENABLE_SECRET_KEY" :tenable-secret-key :string)
    ("TENABLE_SCAN_ID" :tenable-scan-id :string)
    ("TENABLE_TEMPLATE_UUID" :tenable-template-uuid :string)
    ("BRIDGE_POLICY" :policy :string)
    ("BRIDGE_FINDINGS" :findings :string)
    ("BRIDGE_REPORT" :report :string)
    ("BRIDGE_MOCK" :mock :boolean)))

(defun env-config ()
  "Read BRIDGE_*/CYBERARK_*/CONJUR_*/TENABLE_* environment variables."
  (let ((config (bridge-gate.util:make-map)))
    (dolist (entry *environment* config)
      (destructuring-bind (variable key kind) entry
        (let ((value (getenv variable)))
          (when value
            (setf (gethash key config)
                  (ecase kind
                    (:string value)
                    (:mode
                     (intern (string-upcase (string-downcase value)) :keyword))
                    (:tenable-mode
                     (intern (string-upcase
                              (string-downcase
                               (bridge-gate.util:replace-all "_" "-" value)))
                             :keyword))
                    (:boolean
                     (if (truthy-string-p value) t :false))))))))))

(defun file-config (path)
  "Read an EDN config file. Returns an empty map when absent or invalid."
  (handler-case
      (let ((probe (and path (probe-file path))))
        (if probe
            (let ((value (bridge-gate.edn:read-edn-file probe)))
              (if (hash-table-p value) value (bridge-gate.util:make-map)))
            (bridge-gate.util:make-map)))
    (error () (bridge-gate.util:make-map))))

(defun compact (map)
  "Drop nil-valued entries so unset CLI flags do not clobber env/file config."
  (let ((copy (bridge-gate.util:copy-map map)))
    (dolist (key (bridge-gate.util:map-keys copy))
      (when (null (gethash key copy))
        (remhash key copy)))
    copy))

(defun load-config (&optional (cli-options (bridge-gate.util:make-map)))
  "Merge defaults <- config.edn <- environment <- CLI options."
  (let* ((cli (compact cli-options))
         (config-file (or (gethash :config-file cli) "config.edn"))
         (config (defaults)))
    (bridge-gate.util:merge-maps config (file-config config-file))
    (bridge-gate.util:merge-maps config (env-config))
    (remhash :config-file cli)
    (remhash :help cli)
    (bridge-gate.util:merge-maps config cli)
    config))
