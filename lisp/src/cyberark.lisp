;;;; cyberark.lisp --- CyberArk credential fetching (CCP and Conjur).

(in-package #:bridge-gate.cyberark)

(defparameter *mock-credential*
  (bridge-gate.util:make-map
   :username "svc-deploy"
   :secret "M0ck-S3cret-0ffl1ne-0nly"
   :expiry "2030-01-01T00:00:00Z"))

(defun mock-credential ()
  (bridge-gate.util:copy-map *mock-credential*))

(defun default-client (request)
  (bridge-gate.http:default-client request))

(defun parse-body (body)
  (cond
    ((null body) (bridge-gate.util:make-map))
    ((hash-table-p body) body)
    ((stringp body)
     (handler-case
         (let ((value (bridge-gate.json:parse body)))
           (if (hash-table-p value) value (bridge-gate.util:make-map)))
       (error () (bridge-gate.util:make-map))))
    (t (bridge-gate.util:make-map))))

(defun require-keys (config keys label)
  (dolist (key keys)
    (when (bridge-gate.util:blankp (bridge-gate.util:map-get config key))
      (bridge-gate.conditions:app-error*
       (format nil "Missing required ~a config: ~a"
               label (bridge-gate.util:keyword-name key))
       (list :missing key)))))

(defun fetch-ccp (config client)
  (require-keys config
                '(:cyberark-base-url :cyberark-app-id
                  :cyberark-safe :cyberark-object)
                "CyberArk CCP")
  (let* ((base (bridge-gate.util:strip-trailing-slash
                (bridge-gate.util:to-string
                 (bridge-gate.util:map-get config :cyberark-base-url))))
         (uri (format nil "~a/AIMWebService/api/Accounts" base))
         (response (funcall client
                            (list :method :get
                                  :uri uri
                                  :query-params
                                  (list (cons "AppID" (bridge-gate.util:to-string
                                                       (bridge-gate.util:map-get
                                                        config :cyberark-app-id)))
                                        (cons "Safe" (bridge-gate.util:to-string
                                                      (bridge-gate.util:map-get
                                                       config :cyberark-safe)))
                                        (cons "Object" (bridge-gate.util:to-string
                                                        (bridge-gate.util:map-get
                                                         config :cyberark-object))))
                                  :headers (list (cons "Accept" "application/json")))))
         (body (parse-body (getf response :body))))
    (unless (= 200 (getf response :status))
      (bridge-gate.conditions:app-error*
       "CyberArk CCP request failed"
       (list :status (getf response :status) :body body)))
    (bridge-gate.util:make-map
     :username (gethash "UserName" body)
     :secret (gethash "Content" body)
     :expiry (gethash "Expiry" body "unknown"))))

(defun fetch-conjur (config client)
  (require-keys config
                '(:conjur-appliance-url :conjur-authn-login
                  :conjur-api-key :conjur-secret-var)
                "CyberArk Conjur")
  (let* ((base (bridge-gate.util:strip-trailing-slash
                (bridge-gate.util:to-string
                 (bridge-gate.util:map-get config :conjur-appliance-url))))
         (account (or (bridge-gate.util:map-get config :conjur-account) "default"))
         (login (bridge-gate.util:to-string
                 (bridge-gate.util:map-get config :conjur-authn-login)))
         (auth-response
           (funcall client
                    (list :method :post
                          :uri (format nil "~a/authn/~a/~a/authenticate"
                                       base account login)
                          :headers (list (cons "Content-Type" "text/plain")
                                         (cons "Accept" "application/json"))
                          :body (bridge-gate.util:to-string
                                 (bridge-gate.util:map-get config :conjur-api-key))))))
    (unless (= 200 (getf auth-response :status))
      (bridge-gate.conditions:app-error*
       "Conjur authentication failed"
       (list :status (getf auth-response :status))))
    (let* ((token (bridge-gate.util:trim
                   (bridge-gate.util:to-string (getf auth-response :body))))
           (variable (bridge-gate.util:strip-leading-slashes
                      (bridge-gate.util:to-string
                       (bridge-gate.util:map-get config :conjur-secret-var))))
           (secret-response
             (funcall client
                      (list :method :get
                            :uri (format nil "~a/secrets/~a/variable/~a"
                                         base account variable)
                            :headers (list (cons "Authorization"
                                                 (format nil "Token token=\"~a\"" token))
                                           (cons "Accept" "application/json"))))))
      (unless (= 200 (getf secret-response :status))
        (bridge-gate.conditions:app-error*
         "Conjur secret fetch failed"
         (list :status (getf secret-response :status))))
      (bridge-gate.util:make-map
       :username login
       :secret (bridge-gate.util:trim
                (bridge-gate.util:to-string (getf secret-response :body)))
       :expiry "session"))))

(defun fetch-credential (config &optional (client #'default-client))
  "Fetch a credential map (:username :secret :expiry).
   With (:MOCK config) truthy, returns static mock data without any network."
  (if (bridge-gate.util:truthy (bridge-gate.util:map-get config :mock))
      (mock-credential)
      (case (bridge-gate.util:map-get config :cyberark-mode)
        (:ccp (fetch-ccp config client))
        (:conjur (fetch-conjur config client))
        (t
         (bridge-gate.conditions:app-error*
          "Unknown CYBERARK_MODE (want :ccp or :conjur)"
          (list :mode (bridge-gate.util:map-get config :cyberark-mode)))))))
