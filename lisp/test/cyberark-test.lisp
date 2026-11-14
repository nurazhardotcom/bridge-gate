;;;; cyberark-test.lisp --- Ported CyberArk connector tests (offline, mock client).

(defpackage #:bridge-gate/cyberark-test
  (:use #:cl #:bridge-gate/test-support))

(in-package #:bridge-gate/cyberark-test)

(defun ccp-config ()
  (ht :mock :false
      :cyberark-mode :ccp
      :cyberark-base-url "https://ccp.example.com"
      :cyberark-app-id "App1"
      :cyberark-safe "Safe1"
      :cyberark-object "Obj1"))

(defun conjur-config ()
  (ht :mock :false
      :cyberark-mode :conjur
      :conjur-appliance-url "https://conjur.example.com"
      :conjur-account "default"
      :conjur-authn-login "host/bridge/ci"
      :conjur-api-key "APIKEY"
      :conjur-secret-var "ci/deploy/key"))

(deftest ccp-normalizes-account
  (testing "CCP JSON response is normalized to (:username :secret :expiry)"
    (let (seen)
      (flet ((client (request)
               (setf seen request)
               (response 200
                         "{\"UserName\":\"svc-deploy\",\"Content\":\"s3cret!\",\"Expiry\":\"2030-01-01\"}")))
        (let* ((credential (bridge-gate.cyberark:fetch-credential
                            (ccp-config) #'client))
               (query (getf seen :query-params)))
          (ok (string= "svc-deploy" (hget credential :username)))
          (ok (string= "s3cret!" (hget credential :secret)))
          (ok (string= "2030-01-01" (hget credential :expiry)))
          (ok (eq :get (getf seen :method)))
          (ok (bridge-gate.util:ends-with-p
               "/AIMWebService/api/Accounts" (getf seen :uri)))
          (ok (string= "App1" (query-value query "AppID")))
          (ok (string= "Safe1" (query-value query "Safe")))
          (ok (string= "Obj1" (query-value query "Object"))))))))

(deftest ccp-failure-throws
  (testing "non-200 CCP response throws with status"
    (flet ((client (request)
             (declare (ignore request))
             (response 401 "unauthorized")))
      (ok (signals-p (lambda ()
                       (bridge-gate.cyberark:fetch-credential
                        (ccp-config) #'client)))))))

(deftest ccp-missing-config-throws
  (testing "missing CCP config keys throw before any HTTP call"
    (let ((called nil)
          (config (ccp-config)))
      (remhash :cyberark-safe config)
      (flet ((client (request)
               (declare (ignore request))
               (setf called t)
               (response 200 "{}")))
        (ok (signals-p (lambda ()
                         (bridge-gate.cyberark:fetch-credential
                          config #'client))))
        (ok (null called))))))

(deftest conjur-two-step-auth
  (testing "Conjur authenticates then fetches the secret with the token header"
    (let ((calls '()))
      (flet ((client (request)
               (setf calls (append calls (list request)))
               (if (bridge-gate.util:ends-with-p
                    "/authenticate" (getf request :uri))
                   (response 200 "TOKEN-ABC")
                   (response 200 " siêu-secret "))))
        (let ((credential (bridge-gate.cyberark:fetch-credential
                           (conjur-config) #'client)))
          (ok (= 2 (length calls)))
          (ok (string= "host/bridge/ci" (hget credential :username)))
          (ok (string= "siêu-secret" (hget credential :secret)))
          (ok (string= "Token token=\"TOKEN-ABC\""
                       (header-value (getf (second calls) :headers)
                                     "Authorization"))))))))

(deftest conjur-auth-failure-throws
  (testing "failed Conjur authn throws"
    (flet ((client (request)
             (declare (ignore request))
             (response 403 "forbidden")))
      (ok (signals-p (lambda ()
                       (bridge-gate.cyberark:fetch-credential
                        (conjur-config) #'client)))))))

(deftest mock-mode-returns-static-credential
  (testing "--mock returns static creds and never touches the client"
    (let ((called nil))
      (flet ((client (request)
               (declare (ignore request))
               (setf called t)
               (error "must not be called")))
        (let ((credential (bridge-gate.cyberark:fetch-credential
                           (ht :mock t :cyberark-mode :ccp)
                           #'client)))
          (ok (string= "svc-deploy" (hget credential :username)))
          (ok (stringp (hget credential :secret)))
          (ok (null called)))))))

(deftest unknown-mode-throws
  (testing "unknown :cyberark-mode throws"
    (flet ((client (request)
             (declare (ignore request))
             (response 200 "{}")))
      (ok (signals-p (lambda ()
                       (bridge-gate.cyberark:fetch-credential
                        (ht :mock :false :cyberark-mode :nope)
                        #'client)))))))
