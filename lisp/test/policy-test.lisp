;;;; policy-test.lisp --- Ported and extended policy engine tests.

(defpackage #:bridge-gate/policy-test
  (:use #:cl #:bridge-gate/test-support))

(in-package #:bridge-gate/policy-test)

(defun clean-findings ()
  (vector
   (ht :host "10.0.0.1" :plugin-id "10180" :name "Ping" :severity :info :port 0)
   (ht :host "10.0.0.1" :plugin-id "11219" :name "SYN" :severity :low :port 22)))

(defun dirty-findings ()
  (vector
   (ht :host "10.0.0.2" :plugin-id "10001" :name "Bad Plugin"
       :severity :critical :port 0)
   (ht :host "10.0.0.2" :plugin-id "33850" :name "Unsupported OS"
       :severity :high :port 0)
   (ht :host "10.0.0.2" :plugin-id "51192" :name "SSL"
       :severity :medium :port 443)
   (ht :host "10.0.0.2" :name "No plugin id" :severity :low :port 0)))

(defun base-policy ()
  (ht :name "test gate"
      :rules (ht :max-criticals 0
                 :max-highs 0
                 :max-mediums 50
                 :max-severity :high
                 :blocked-plugins '(10001 20002)
                 :required-fields #(:host :plugin-id :severity))))

(defun rules-of (policy)
  (ht :rules (bridge-gate.util:copy-map (hget policy :rules))))

(defun violation-rules (result)
  (map 'list (lambda (violation) (hget violation :rule))
       (hget result :violations)))

(deftest clean-findings-pass
  (testing "clean findings produce passed? true with zero violations"
    (let* ((result (bridge-gate.policy:evaluate (clean-findings) (base-policy)))
           (summary (hget result :summary)))
      (ok (eq t (hget result :passed?)))
      (ok (zerop (length (hget result :violations))))
      (ok (= 2 (hget summary :total)))
      (ok (= 1 (hget summary :low))))))

(deftest dirty-findings-fail
  (testing "criticals, highs, blocked plugins, and missing fields all violate"
    (let* ((result (bridge-gate.policy:evaluate (dirty-findings) (base-policy)))
           (rules (violation-rules result)))
      (ok (eq :false (hget result :passed?)))
      (ok (member :max-criticals rules))
      (ok (member :max-highs rules))
      (ok (member :blocked-plugins rules))
      (ok (member :required-fields rules)))))

(deftest medium-budget
  (testing ":max-mediums is enforced only when present"
    (let ((mediums (coerce
                    (loop for index from 0 below 3
                          collect (ht :host "h"
                                      :plugin-id (format nil "~a" (+ 9000 index))
                                      :severity :medium))
                    'vector)))
      (let ((limited (base-policy)))
        (setf (gethash :max-mediums (hget limited :rules)) 1)
        (ok (eq :false
                (hget (bridge-gate.policy:evaluate mediums limited) :passed?))))
      (let* ((unlimited (base-policy))
             (rules (hget unlimited :rules)))
        (remhash :max-mediums rules)
        ;; The original test passes the rules map itself; evaluate then falls
        ;; back to its default rule set.
        (ok (eq t
                (hget (bridge-gate.policy:evaluate mediums rules) :passed?)))))))

(deftest max-severity-rule
  (testing ":max-severity flags anything above the threshold"
    (let* ((highs (vector (ht :host "h" :plugin-id "1" :severity :high)))
           (policy (ht :rules (ht :max-severity :medium)))
           (result (bridge-gate.policy:evaluate highs policy)))
      (ok (eq :false (hget result :passed?)))
      (ok (member :max-severity (violation-rules result))))))

(deftest string-severities-coerced
  (testing "string severities from JSON round-trips are coerced before evaluation"
    (let ((result (bridge-gate.policy:evaluate
                   (vector (ht :host "h" :plugin-id "9" :severity "CRITICAL"))
                   (base-policy))))
      (ok (eq :false (hget result :passed?)))
      (ok (= 1 (hget (hget result :summary) :critical))))))

(deftest shipped-policy-loads
  (testing "policies/mas_trm.edn loads and gates the mock shape correctly"
    (let* ((policy (bridge-gate.policy:load-policy "policies/mas_trm.edn"))
           (rules (hget policy :rules)))
      (ok (= 0 (hget rules :max-criticals)))
      (ok (= 0 (hget rules :max-highs)))
      (ok (member 10001 (hget rules :blocked-plugins))))))

(deftest missing-policy-throws
  (testing "unknown policy path throws"
    (ok (signals-p (lambda ()
                     (bridge-gate.policy:load-policy "policies/nope.edn"))))))

(deftest block-payload-shape
  (testing "build-block-payload emits ServiceNow + Slack structures"
    (let* ((result (bridge-gate.policy:evaluate (dirty-findings) (base-policy)))
           (payload (bridge-gate.policy:build-block-payload
                     result
                     (ht :target "10.0.0.2"
                         :scan-id "s-1"
                         :policy "policies/mas_trm.edn")))
           (servicenow (hget payload :servicenow))
           (slack (hget payload :slack)))
      (ok (eq :false (hget payload :passed?)))
      (ok (string= "10.0.0.2" (hget payload :target)))
      (ok (string= "1" (hget servicenow :urgency)))
      (ok (string= "Security Operations" (hget servicenow :assignment_group)))
      (ok (stringp (hget slack :text)))
      (ok (plusp (length (hget slack :blocks)))))))
