;;;; tenable-test.lisp --- Ported Tenable connector tests (offline, mock clients).

(defpackage #:bridge-gate/tenable-test
  (:use #:cl #:bridge-gate/test-support))

(in-package #:bridge-gate/tenable-test)

(deftest severity-coercion
  (testing "vendor severities coerce to keywords, fail-closed on unknown"
    (dolist (pair '((:critical :critical)
                    (:high :high)
                    ("Critical" :critical)
                    ("HIGH" :high)
                    ("medium" :medium)
                    ("Med" :medium)
                    ("low" :low)
                    ("info" :info)
                    ("none" :info)
                    (4 :critical)
                    (3 :high)
                    (2 :medium)
                    (1 :low)
                    (0 :info)
                    ("bogus-string" :critical)
                    (99 :critical)
                    (nil :critical)
                    (:weird-kw :critical)))
      (ok (eq (second pair)
              (bridge-gate.tenable:coerce-severity (first pair)))
          (format nil "~s should coerce to ~s" (first pair) (second pair))))))

(deftest mock-scan-shape
  (testing "mock payload has 1 high, 2 medium, 0 critical"
    (let* ((scan (bridge-gate.tenable:run-scan
                  (ht :mock t) "10.10.50.12"))
           (findings (hget scan :findings))
           (counts (ht)))
      (dolist (finding (coerce findings 'list))
        (let ((severity (hget finding :severity)))
          (setf (gethash severity counts)
                (1+ (gethash severity counts 0)))))
      (ok (string= "10.10.50.12" (hget scan :target)))
      (ok (string= "completed" (hget scan :status)))
      (ok (= 1 (gethash :high counts 0)))
      (ok (= 2 (gethash :medium counts 0)))
      (ok (= 0 (gethash :critical counts 0)))
      (ok (every (lambda (finding) (hhas finding :host))
                 (coerce findings 'list)))
      (ok (every (lambda (finding) (hhas finding :plugin-id))
                 (coerce findings 'list))))))

(deftest missing-target-throws
  (testing "blank target throws"
    (ok (signals-p (lambda ()
                     (bridge-gate.tenable:run-scan (ht :mock :false) ""))))))

(defun io-config ()
  (ht :mock :false
      :tenable-mode :tenable-io
      :tenable-base-url "https://cloud.tenable.com"
      :tenable-access-key "AK"
      :tenable-secret-key "SK"
      :tenable-scan-id 42
      :poll-interval-ms 0
      :poll-max-attempts 10))

(defun io-client ()
  "Queued Tenable.io responses: launch -> queued -> running -> completed,
   export -> loading -> ready -> download."
  (let ((states (list "queued" "running" "completed"))
        (export-states (list "loading" "ready")))
    (lambda (request)
      (let ((uri (getf request :uri)))
        (cond
          ((bridge-gate.util:ends-with-p "/launch" uri)
           (response 200 "{\"scan_uuid\":\"uuid-42\"}"))
          ((search "/export/" uri)
           (if (bridge-gate.util:ends-with-p "/status" uri)
               (response 200
                         (format nil "{\"status\":\"~a\"}"
                                 (pop export-states)))
               (response 200
                         (concatenate
                          'string
                          "[{\"plugin_id\":10001,\"plugin_name\":\"Bad Plugin\","
                          "\"severity\":\"Critical\",\"hostname\":\"10.0.0.9\",\"port\":0},"
                          "{\"plugin_id\":10180,\"plugin_name\":\"Ping\","
                          "\"severity\":0,\"hostname\":\"10.0.0.9\",\"port\":0}]"))))
          ((bridge-gate.util:ends-with-p "/export" uri)
           (response 200 "{\"file\":7}"))
          (t
           (response 200
                     (format nil "{\"info\":{\"status\":\"~a\"}}"
                             (pop states)))))))))

(deftest tenable-io-full-loop
  (testing "launch -> poll -> export -> download normalizes findings"
    (let* ((scan (bridge-gate.tenable:run-scan
                  (io-config) "10.0.0.9" (io-client)))
           (findings (hget scan :findings)))
      (ok (string= "uuid-42" (hget scan :scan-id)))
      (ok (string= "completed" (hget scan :status)))
      (ok (= 2 (length findings)))
      (ok (eq :critical (hget (aref findings 0) :severity)))
      (ok (string= "10001" (hget (aref findings 0) :plugin-id)))
      (ok (eq :info (hget (aref findings 1) :severity))))))

(deftest tenable-io-poll-timeout
  (testing "scan that never completes throws after max attempts"
    (flet ((client (request)
             (if (bridge-gate.util:ends-with-p "/launch" (getf request :uri))
                 (response 200 "{\"scan_uuid\":\"u\"}")
                 (response 200 "{\"info\":{\"status\":\"running\"}}"))))
      (let ((config (io-config)))
        (setf (gethash :poll-max-attempts config) 2)
        (ok (signals-p (lambda ()
                         (bridge-gate.tenable:run-scan
                          config "10.0.0.9" #'client))))))))

(defun sc-config ()
  (ht :mock :false
      :tenable-mode :tenable-sc
      :tenable-base-url "https://sc.example.com"
      :tenable-access-key "admin"
      :tenable-secret-key "pw"
      :tenable-scan-id 7
      :poll-interval-ms 0
      :poll-max-attempts 10))

(deftest tenable-sc-full-loop
  (testing "token -> launch -> poll -> analysis normalizes findings"
    (let ((states (list "Running" "Completed"))
          (seen '()))
      (flet ((client (request)
               (setf seen (append seen (list request)))
               (let ((uri (getf request :uri)))
                 (cond
                   ((bridge-gate.util:ends-with-p "/rest/token" uri)
                    (response 200 "{\"response\":{\"token\":\"TOK\"}}"))
                   ((bridge-gate.util:ends-with-p "/launch" uri)
                    (response 200 "{\"response\":{\"scanResultID\":99}}"))
                   ((bridge-gate.util:starts-with-p
                     "https://sc.example.com/rest/scanResult/" uri)
                    (response 200
                              (format nil "{\"response\":{\"status\":\"~a\"}}"
                                      (pop states))))
                   (t
                    (response
                     200
                     (concatenate
                      'string
                      "{\"response\":{\"results\":[{\"pluginID\":\"20002\","
                      "\"name\":\"SC Vuln\",\"severity\":\"High\","
                      "\"host\":\"10.0.0.5\",\"port\":443}]}}")))))))
        (let* ((scan (bridge-gate.tenable:run-scan
                      (sc-config) "10.0.0.5" #'client))
               (findings (hget scan :findings)))
          (ok (string= "99" (hget scan :scan-id)))
          (ok (= 1 (length findings)))
          (ok (eq :high (hget (aref findings 0) :severity)))
          (ok (string= "20002" (hget (aref findings 0) :plugin-id)))
          (ok (some (lambda (request)
                      (string= "TOK"
                               (header-value (getf request :headers)
                                             "X-SecurityCenter")))
                    (rest seen))))))))
