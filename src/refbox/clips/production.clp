
;---------------------------------------------------------------------------
;  production.clp - LLSF RefBox CLIPS production phase rules
;
;  Created: Thu Feb 07 19:31:12 2013
;  Copyright  2013  Tim Niemueller [www.niemueller.de]
;  Licensed under BSD license, cf. LICENSE file
;---------------------------------------------------------------------------

(deffunction any-puck-in-state (?puck-state $?puck-ids)
  (foreach ?id ?puck-ids
    (if (any-factp ((?puck puck)) (and (eq ?puck:id ?id) (eq ?puck:state ?puck-state)))
      then (return TRUE)))
  (return FALSE)
)

(defrule machine-enable-production
  ?gs <- (gamestate (phase PRODUCTION) (prev-phase ~PRODUCTION))
  ?sf <- (signal (type machine-info-bc))
  =>
  (modify ?gs (prev-phase PRODUCTION) (game-time 0.0))

  ; trigger machine info burst period
  (modify ?sf (count 1) (time 0 0))

  (if (not (any-factp ((?mi machines-initialized)) TRUE))
   then (machine-init-randomize))

  ; reset late orders, assign random times
  (delayed-do-for-all-facts ((?order order)) (eq ?order:late-order TRUE)
    (bind ?deliver-start
      (random (nth$ 1 ?order:late-order-start-period) (nth$ 2 ?order:late-order-start-period)))
    (bind ?deliver-end (+ ?deliver-start 120))
    (bind ?activate-at (max (- ?deliver-start 5) 0))
    (printout t "Late order " ?order:id ": from " (time-sec-format ?deliver-start)
	      " to " (time-sec-format ?deliver-end) crlf)
    (modify ?order (active FALSE) (activate-at ?activate-at)
	    (delivery-period ?deliver-start ?deliver-end))
  )
  ; assign random quantities to non-late orders
  (delayed-do-for-all-facts ((?order order)) (neq ?order:late-order TRUE)
    (modify ?order (quantity-requested (random 3 10)))
  )

  ; Set lights
  (delayed-do-for-all-facts ((?machine machine)) TRUE
    (modify ?machine (desired-lights GREEN-ON))
  )

  (assert (attention-message "Entering Production Phase" 5))
)

(defrule machine-down
  (declare (salience ?*PRIORITY_HIGH*))
  (time $?now)
  (gamestate (phase PRODUCTION) (state RUNNING) (game-time ?gtime))
  ?mf <- (machine (name ?name) (state ?state&~DOWN) (proc-start $?proc-start)
		  (down-period $?dp&:(<= (nth$ 1 ?dp) ?gtime)&:(>= (nth$ 2 ?dp) ?gtime)))
  =>
  (bind ?down-time (- (nth$ 2 ?dp) (nth$ 1 ?dp)))
  (printout t "Machine " ?name " down for " ?down-time " sec" crlf)
  (if (eq ?state PROCESSING)
   then
    (modify ?mf (state DOWN) (desired-lights RED-ON) (prev-state ?state)
	    (proc-start (+ (nth$ 1 ?proc-start) ?down-time) (nth$ 2 ?proc-start)))
   else
    (modify ?mf (state DOWN) (prev-state ?state) (desired-lights RED-ON))
  )
)

(defrule machine-up
  (declare (salience ?*PRIORITY_HIGH*))
  (time $?now)
  (gamestate (phase PRODUCTION) (state RUNNING) (game-time ?gtime))
  ?mf <- (machine (name ?name) (state DOWN) (prev-state ?prev-state)
		  (down-period $?dp&:(<= (nth$ 2 ?dp) ?gtime)))
  =>
  (printout t "Machine " ?name " is up again" crlf)
  (switch ?prev-state
    (case PROCESSING then (modify ?mf (state PROCESSING) (desired-lights GREEN-ON YELLOW-ON)))
    (case WAITING    then (modify ?mf (state WAITING)    (desired-lights YELLOW-ON)))
    (case INVALID    then (modify ?mf (state INVALID)    (desired-lights YELLOW-BLINK)))
    (case IDLE       then (modify ?mf (state IDLE)       (desired-lights GREEN-ON)))
  )
)


(defrule machine-proc-start
  (time $?now)
  (gamestate (state RUNNING) (phase PRODUCTION))
  (rfid-input (machine ?m) (has-puck TRUE) (id ?id&~0))
  (machine (name ?m) (mtype ?mtype&~DELIVER&~TEST&~RECYCLE))
  (machine-spec (mtype ?mtype)  (inputs $?inputs)
		(proc-time ?pt))
  (puck (id ?id) (state ?ps&:(member$ ?ps ?inputs)))
  ?mf <- (machine (name ?m) (mtype ?mtype) (state IDLE|WAITING)
		  (loaded-with $?lw&:(not (any-puck-in-state ?ps ?lw))))
  (not (or (machine (name ?m2&~?m) (puck-id ?m2-pid&?id))
	   (machine (name ?m2&~?m) (loaded-with $?m2-lw&:(member$ ?id ?m2-lw)))))
  =>
  (if (= (+ (length$ ?lw) 1) (length$ ?inputs)) then
    ; last puck to add
    (bind ?proc-time ?pt)
   else
    ; intermediate puck to add
    (bind ?proc-time ?*INTERMEDIATE-PROC-TIME*)
  )
  (printout t "Production begins at " ?m " (will take " ?proc-time " sec)" crlf)
  (modify ?mf (puck-id ?id) (state PROCESSING) (proc-start ?now) (proc-time ?proc-time)
	  (desired-lights GREEN-ON YELLOW-ON))
)


(defrule machine-invalid-input
  (time $?now)
  (gamestate (state RUNNING) (phase PRODUCTION))
  (rfid-input (machine ?m) (has-puck TRUE) (id ?id&~0))
  (machine (name ?m) (mtype ?mtype&~DELIVER&~TEST&~RECYCLE))
  (machine-spec (mtype ?mtype)  (inputs $?inputs))
  (not (or (machine (name ?m2&~?m) (puck-id ?m2-pid&?id))
	   (machine (name ?m2&~?m) (loaded-with $?m2-lw&:(member$ ?id ?m2-lw)))))
  (or (and (puck (id ?id) (state ?ps&:(not (member$ ?ps ?inputs))))
	   ?mf <- (machine (name ?m) (state IDLE|WAITING) (puck-id 0)))
      ; OR:
      (and (puck (id ?id) (state ?ps&:(member$ ?ps ?inputs)))
	   ?mf <- (machine (name ?m) (state IDLE|WAITING) (puck-id 0)
			   (loaded-with $?lw&:(any-puck-in-state ?ps ?lw))))
  )
  =>
  (modify ?mf (puck-id ?id) (state INVALID) (desired-lights YELLOW-BLINK))
)

(defrule machine-invalid-input-junk
  "A puck was placed that was already placed at another machine"
  (time $?now)
  (gamestate (state RUNNING) (phase PRODUCTION))
  (rfid-input (machine ?m) (has-puck TRUE) (id ?id&~0))
  ?mf <- (machine (name ?m) (mtype ?mtype&~DELIVER&~TEST&~RECYCLE))
  ?pf <- (puck (id ?id))
  (or (machine (name ?m2&~?m) (puck-id ?m2-pid&?id))
      (machine (name ?m2&~?m) (loaded-with $?m2-lw&:(member$ ?id ?m2-lw))))
  =>
  (modify ?mf (puck-id ?id) (state INVALID) (desired-lights YELLOW-BLINK))
  (modify ?pf (state CONSUMED))
  (delayed-do-for-all-facts ((?machine machine)) (member$ ?id ?machine:loaded-with)
    (modify ?machine (loaded-with (delete-member$ ?machine:loaded-with ?id)))
  )
)

(defrule machine-proc-waiting
  (time $?now)
  (gamestate (state RUNNING) (phase PRODUCTION))
  (machine (name ?m) (mtype ?mtype&~DELIVER&~TEST&~RECYCLE) (state PROCESSING))
  (machine-spec (mtype ?mtype)  (inputs $?inputs))
  ?mf <- (machine (name ?m) (mtype ?mtype) (puck-id ?id)
		  (loaded-with $?lw&:(< (+ (length$ ?lw) 1) (length$ ?inputs)))
		  (proc-time ?pt) (proc-start $?pstart&:(timeout ?now ?pstart ?pt)))
  ?pf <- (puck (id ?id) (state ?ps))
  =>
  (printout t ?mtype ": " ?ps " consumed @ " ?m ": " ?id crlf)
  (modify ?mf (state WAITING) (loaded-with (create$ ?lw ?id)) (desired-lights YELLOW-ON))
)

(defrule machine-proc-done
  (time $?now)
  (gamestate (state RUNNING) (phase PRODUCTION))
  ?gf <- (gamestate (points ?points))
  (machine (name ?m) (mtype ?mtype) (state PROCESSING))
  (machine-spec (mtype ?mtype&~DELIVER&~TEST&~RECYCLE)
		(inputs $?inputs) (output ?output) (points ?machine-points))
  ?mf <- (machine (name ?m) (mtype ?mtype) (puck-id ?id)
		  (loaded-with $?lw&:(= (+ (length$ ?lw) 1) (length$ ?inputs)))
		  (productions ?p)
		  (proc-time ?pt) (proc-start $?pstart&:(timeout ?now ?pstart ?pt)))
  ?pf <- (puck (id ?id) (state ?ps))
  =>
  (printout t ?mtype " production done @ " ?m ": " ?id " (" ?ps
	    " -> " ?output ", took " ?pt " sec, awarding " ?machine-points " points)" crlf)
  (modify ?mf (state IDLE) (loaded-with)  (desired-lights GREEN-ON)
	  (productions (+ ?p 1)))
  (modify ?gf (points (+ ?points ?machine-points)))
  (modify ?pf (state ?output))
  (foreach ?puck-id ?lw
    (do-for-fact ((?puck puck)) (= ?puck:id ?puck-id)
      (modify ?puck (state CONSUMED))
    )
  )
)

(defrule machine-puck-removal
  (gamestate (state RUNNING) (phase PRODUCTION))
  (rfid-input (machine ?m) (has-puck FALSE))
  ?mf <- (machine (name ?m) (state ?state) (mtype ?mtype&~DELIVER&~TEST&~RECYCLE)
		  (loaded-with $?lw) (puck-id ?id&~0))
  =>
  (if (eq ?state DOWN)
   then
    (if (> (length$ ?lw) 0) then
      (modify ?mf (prev-state WAITING) (puck-id 0))
     else
      (modify ?mf (prev-state IDLE) (puck-id 0))
    )
   else
    (if (> (length$ ?lw) 0) then
      (modify ?mf (state WAITING) (puck-id 0) (desired-lights YELLOW-ON))
     else
      (modify ?mf (state IDLE) (puck-id 0)  (desired-lights GREEN-ON))
    )
  )
)

(defrule deliver-proc-start
  (time $?now)
  (gamestate (state RUNNING) (phase PRODUCTION))
  (rfid-input (machine ?m) (has-puck TRUE) (id ?id&~0))
  ?mf <- (machine (name ?m) (mtype DELIVER) (state IDLE))
  (puck (id ?id) (state ?ps))
  (order (active TRUE) (product ?product&:(eq ?product ?ps)))
  =>
  (modify ?mf (puck-id ?id) (state PROCESSING) (proc-start ?now)
	  (proc-time ?*DELIVER-PROC-TIME*) (desired-lights GREEN-ON YELLOW-ON))
)


(defrule deliver-invalid-input
  (time $?now)
  (gamestate (state RUNNING) (phase PRODUCTION))
  (rfid-input (machine ?m) (has-puck TRUE) (id ?id&~0))
  ?mf <- (machine (name ?m) (mtype DELIVER) (state IDLE) (puck-id 0))
  (puck (id ?id) (state ?ps))
  (not (order (active TRUE) (product ?product&:(eq ?product ?ps))))
  =>
  (modify ?mf (puck-id ?id) (state INVALID) (desired-lights YELLOW-BLINK))
)

(defrule deliver-proc-done
  (time $?now)
  (gamestate (state RUNNING) (phase PRODUCTION))
  ?mf <- (machine (name ?m) (mtype DELIVER) (state PROCESSING) (puck-id ?id) (productions ?p)
		  (proc-time ?pt) (proc-start $?pstart&:(timeout ?now ?pstart ?pt)))
  ?pf <- (puck (id ?id) (state ?ps))
  =>
  (printout t "Delivered " ?ps " @ " ?m ": " ?id " (" ?ps " -> CONSUMED)" crlf)
  (modify ?mf (state IDLE) (productions (+ ?p 1)) (desired-lights GREEN-ON YELLOW-ON RED-ON))
  (modify ?pf (state CONSUMED))
  (assert (product-delivered (time ?now) (product ?ps) (delivery-gate ?m))) 
)

(defrule deliver-removal
  (gamestate (state RUNNING) (phase PRODUCTION))
  (rfid-input (machine ?m) (has-puck FALSE))
  ?mf <- (machine (name ?m) (mtype DELIVER) (puck-id ?id&~0))
  =>
  (modify ?mf (state IDLE) (puck-id 0) (desired-lights GREEN-ON))
)


(defrule recycle-proc-start
  (time $?now)
  (gamestate (state RUNNING) (phase PRODUCTION))
  (rfid-input (machine ?m) (has-puck TRUE) (id ?id&~0))
  ?mf <- (machine (name ?m) (mtype RECYCLE) (state IDLE))
  (puck (id ?id) (state CONSUMED))
  =>
  (modify ?mf (puck-id ?id) (state PROCESSING) (proc-start ?now)
	  (proc-time ?*RECYCLE-PROC-TIME*) (desired-lights GREEN-ON YELLOW-ON))
)

(defrule recycle-invalid-input
  (time $?now)
  (gamestate (state RUNNING) (phase PRODUCTION))
  (rfid-input (machine ?m) (has-puck TRUE) (id ?id&~0))
  ?mf <- (machine (name ?m) (mtype RECYCLE) (state IDLE) (puck-id 0))
  (puck (id ?id) (state ?ps&~CONSUMED))
  =>
  (modify ?mf (puck-id ?id) (state INVALID) (desired-lights YELLOW-BLINK))
)

(defrule recycle-proc-done
  (time $?now)
  (gamestate (state RUNNING) (phase PRODUCTION))
  ?gf <- (gamestate (points ?points))
  ?mf <- (machine (name ?m) (mtype RECYCLE) (state PROCESSING) (puck-id ?id) (productions ?p)
		  (proc-time ?pt) (proc-start $?pstart&:(timeout ?now ?pstart ?pt)))
  ?pf <- (puck (id ?id) (state ?ps&CONSUMED))
  =>
  (printout t "Recycling done @ " ?m ": " ?id " (" ?ps " -> S0). "
	    "Awarding " ?*RECYCLE-POINTS* " points." crlf)
  (modify ?mf (state IDLE) (productions (+ ?p 1)) (desired-lights GREEN-ON))
  (modify ?pf (state S0))
  (modify ?gf (points (+ ?points ?*RECYCLE-POINTS*)))
)

(defrule recycle-removal
  (gamestate (state RUNNING) (phase PRODUCTION))
  (rfid-input (machine ?m) (has-puck FALSE))
  ?mf <- (machine (name ?m) (mtype RECYCLE) (puck-id ?id&~0))
  =>
  (modify ?mf (state IDLE) (puck-id 0) (desired-lights GREEN-ON))
)


(defrule test-consumed
  (time $?now)
  (rfid-input (machine ?m) (has-puck TRUE) (id ?id&~0))
  ?mf <- (machine (name ?m) (mtype TEST) (state IDLE))
  (puck (id ?id) (state CONSUMED))
  =>
  (modify ?mf (puck-id ?id) (state PROCESSING) (desired-lights))
)

(defrule test-s0
  (time $?now)
  (rfid-input (machine ?m) (has-puck TRUE) (id ?id&~0))
  ?mf <- (machine (name ?m) (mtype TEST) (state IDLE))
  (puck (id ?id) (state S0))
  =>
  (modify ?mf (puck-id ?id) (state PROCESSING) (desired-lights YELLOW-ON))
)

(defrule test-s1
  (time $?now)
  (rfid-input (machine ?m) (has-puck TRUE) (id ?id&~0))
  ?mf <- (machine (name ?m) (mtype TEST) (state IDLE))
  (puck (id ?id) (state S1))
  =>
  (modify ?mf (puck-id ?id) (state PROCESSING) (desired-lights YELLOW-ON RED-ON))
)

(defrule test-s2
  (time $?now)
  (rfid-input (machine ?m) (has-puck TRUE) (id ?id&~0))
  ?mf <- (machine (name ?m) (mtype TEST) (state IDLE))
  (puck (id ?id) (state S2))
  =>
  (modify ?mf (puck-id ?id) (state PROCESSING) (desired-lights RED-ON))
)

(defrule test-p1
  (time $?now)
  (rfid-input (machine ?m) (has-puck TRUE) (id ?id&~0))
  ?mf <- (machine (name ?m) (mtype TEST) (state IDLE))
  (puck (id ?id) (state P1))
  =>
  (modify ?mf (puck-id ?id) (state PROCESSING) (desired-lights GREEN-BLINK))
)

(defrule test-p2
  (time $?now)
  (rfid-input (machine ?m) (has-puck TRUE) (id ?id&~0))
  ?mf <- (machine (name ?m) (mtype TEST) (state IDLE))
  (puck (id ?id) (state P2))
  =>
  (modify ?mf (puck-id ?id) (state PROCESSING) (desired-lights YELLOW-BLINK))
)

(defrule test-p3
  (time $?now)
  (rfid-input (machine ?m) (has-puck TRUE) (id ?id&~0))
  ?mf <- (machine (name ?m) (mtype TEST) (state IDLE))
  (puck (id ?id) (state P3))
  =>
  (modify ?mf (puck-id ?id) (state PROCESSING) (desired-lights RED-BLINK))
)

(defrule test-removal
  (rfid-input (machine ?m) (has-puck FALSE))
  ?mf <- (machine (name ?m) (mtype TEST) (puck-id ?id&~0))
  =>
  (modify ?mf (state IDLE) (puck-id 0) (desired-lights GREEN-ON))
)



(defrule prod-net-recv-PlacePuckUnderMachine
  ?pf <- (protobuf-msg (type "llsf_msgs.PlacePuckUnderMachine") (ptr ?p) (rcvd-via STREAM))
  (gamestate (phase PRODUCTION) (state RUNNING))
  =>
  (retract ?pf) ; message will be destroyed after rule completes
  (bind ?id (pb-field-value ?p "puck_id"))
  ; retract all existing rfid-input facts for this puck, can happen if SPS
  ; is enabled and then a network message is received
  (delayed-do-for-all-facts ((?input rfid-input)) (= ?input:id ?id)
    (retract ?input)
  )
  (bind ?machine (sym-cat (pb-field-value ?p "machine_name")))
  (printout t "Placing puck " ?id " under machine " ?machine crlf)
  (assert (rfid-input (machine ?machine) (has-puck TRUE) (id ?id)))
)

(defrule prod-net-recv-PlacePuckUnderMachine-not-running
  ?pf <- (protobuf-msg (type "llsf_msgs.PlacePuckUnderMachine") (ptr ?p) (rcvd-via STREAM))
  (gamestate (phase PRODUCTION) (state ~RUNNING))
  =>
  (retract ?pf) ; message will be destroyed after rule completes
  (bind ?id (pb-field-value ?p "puck_id"))
  (bind ?machine (sym-cat (pb-field-value ?p "machine_name")))
  (printout warn "Cannot place puck " ?id " under machine " ?machine " when not RUNNING" crlf)
)

(defrule prod-net-recv-PlacePuckUnderMachine-illegal
  (declare (salience ?*PRIORITY_HIGH*))
  ?pf <- (protobuf-msg (type "llsf_msgs.PlacePuckUnderMachine") (ptr ?p)
		       (rcvd-via BROADCAST) (rcvd-from ?host ?port))
  =>
  (retract ?pf) ; message will be destroyed after rule completes
  (printout warn "Illegal PlacePuckUnderMachine message received from host " ?host crlf)
)

(defrule prod-net-recv-PlacePuckUnderMachine-out-of-phase
  ?pf <- (protobuf-msg (type "llsf_msgs.PlacePuckUnderMachine") (ptr ?p)
		       (rcvd-via STREAM) (rcvd-from ?host ?port))
  (gamestate (phase ~PRODUCTION))
  =>
  (retract ?pf) ; message will be destroyed after rule completes
  (printout warn "Received PlacePuckUnderMachine while not in PRODUCTION from host " ?host crlf)
)

(defrule prod-net-recv-LoadPuckInMachine
  ?pf <- (protobuf-msg (type "llsf_msgs.LoadPuckInMachine") (ptr ?p)
		       (rcvd-via STREAM) (rcvd-from ?host ?port))
  (gamestate (phase PRODUCTION))
  =>
  (retract ?pf) ; message will be destroyed after rule completes
  (do-for-fact ((?machine machine))
	       (eq ?machine:name (sym-cat (pb-field-value ?p "machine_name")))
    (bind ?puck-id (pb-field-value ?p "puck_id"))
    (if (not (member$ ?puck-id ?machine:loaded-with))
      then
       (bind ?new-loaded-with (create$ ?machine:loaded-with ?puck-id))
       (assert (machine-update-loaded-with ?machine:name ?new-loaded-with))
    )
  )
)

(defrule prod-net-recv-LoadPuckInMachine-illegal
  (declare (salience ?*PRIORITY_HIGH*))
  ?pf <- (protobuf-msg (type "llsf_msgs.LoadPuckInMachine") (ptr ?p)
		       (rcvd-via BROADCAST) (rcvd-from ?host ?port))
  =>
  (retract ?pf) ; message will be destroyed after rule completes
  (printout warn "Illegal LoadPuckInMachine message received from host " ?host crlf)
)

(defrule prod-net-recv-LoadPuckInMachine-out-of-phase
  ?pf <- (protobuf-msg (type "llsf_msgs.LoadPuckInMachine") (ptr ?p)
		       (rcvd-via STREAM) (rcvd-from ?host ?port))
  (gamestate (phase ~PRODUCTION))
  =>
  (retract ?pf) ; message will be destroyed after rule completes
  (printout warn "Received LoadPuckInMachine while not in PRODUCTION from host " ?host crlf)
)

(defrule prod-net-recv-RemovePuckFromMachine
  ?pf <- (protobuf-msg (type "llsf_msgs.RemovePuckFromMachine") (ptr ?p))
  (gamestate (phase PRODUCTION))
  =>
  (retract ?pf) ; message will be destroyed after rule completes
  ;(printout t "Removing from Machine " (pb-field-value ?p "machine_name") crlf) 
  (do-for-fact ((?machine machine))
	       (eq ?machine:name (sym-cat (pb-field-value ?p "machine_name")))
    (bind ?puck-id (pb-field-value ?p "puck_id"))
    (if (= ?machine:puck-id ?puck-id)
      then
        ; retract all existing rfid-input facts for this puck, can happen if SPS
        ; is enabled and then a network message is received
        (delayed-do-for-all-facts ((?input rfid-input)) (= ?input:id ?puck-id)
          (retract ?input)
	)
        (assert (rfid-input (machine (sym-cat (pb-field-value ?p "machine_name")))
			    (has-puck FALSE)))
      else
      (if (member$ ?puck-id ?machine:loaded-with)
        then
	  (bind ?new-loaded-with (delete-member$ ?machine:loaded-with ?puck-id))
	  (assert (machine-update-loaded-with ?machine:name ?new-loaded-with))
      )
    )
  )
)

(defrule prod-net-recv-RemovePuckFromMachine-illegal
  ?pf <- (protobuf-msg (type "llsf_msgs.RemovePuckFromMachine") (ptr ?p)
		       (rcvd-via BROADCAST) (rcvd-from ?host ?port))
  =>
  (retract ?pf) ; message will be destroyed after rule completes
  (printout warn "Illegal RemovePuckFromMachine message received from host " ?host crlf)
)

(defrule prod-net-recv-RemovePuckFromMachine-out-of-phase
  ?pf <- (protobuf-msg (type "llsf_msgs.RemovePuckFromMachine") (ptr ?p)
		       (rcvd-via BROADCAST) (rcvd-from ?host ?port))
  (gamestate (phase ~PRODUCTION))
  =>
  (retract ?pf) ; message will be destroyed after rule completes
  (printout warn "Received RemovePuckFromMachine while not in PRODUCTION from host " ?host crlf)
)


(defrule machine-update-loaded-with-no-inputs
  (declare (salience ?*PRIORITY_HIGH*))
  ?uf <- (machine-update-loaded-with ?m $?new-lw)
  (machine (name ?m) (mtype ?mtype))
  (machine-spec (mtype ?mtype) (inputs $?inputs&:(= (length$ ?inputs) 0)))
  =>
  (retract ?uf)
  (printout t "Ignoring load update " ?new-lw " for " ?m "|" ?mtype " w/o inputs" crlf)
)

(defrule machine-update-loaded-with-full
  (declare (salience ?*PRIORITY_HIGH*))
  ?uf <- (machine-update-loaded-with ?m $?new-lw)
  (machine (name ?m) (mtype ?mtype))
  (machine-spec (mtype ?mtype) (inputs $?inputs&:(< (length$ ?inputs) (length$ ?new-lw))))
  =>
  (retract ?uf)
  (printout t "Ignoring load update " ?new-lw " for " ?m "|" ?mtype " being already full" crlf)
)

(defrule machine-update-loaded-with-puck
  (declare (salience ?*PRIORITY_HIGH*))
  ?uf <- (machine-update-loaded-with ?m $?new-lw)
  (machine (name ?m) (mtype ?mtype) (puck-id ?puck-id&~0))
  (machine-spec (mtype ?mtype) (inputs $?inputs&:(= (length$ ?inputs) (length$ ?new-lw))))
  =>
  (retract ?uf)
  (printout t "Load update conflict " ?new-lw " for " ?m "|" ?mtype
	    " with puck under RFID" crlf)
)

(defrule machine-update-loaded-with-test
  (declare (salience ?*PRIORITY_HIGH*))
  ?gf <- (gamestate (phase PRODUCTION) (points ?points))
  ?uf <- (machine-update-loaded-with ?m $?new-lw)
  =>
  (printout t test crlf)
)

(defrule machine-update-loaded-with
  (declare (salience ?*PRIORITY_HIGH*))
  ?gf <- (gamestate (phase PRODUCTION) (points ?points))
  ?uf <- (machine-update-loaded-with ?m $?new-lw)
  ?mf <- (machine (name ?m) (mtype ?mtype) (loaded-with $?old-lw) (productions ?p))
  (machine-spec (mtype ?mtype) (inputs $?inputs&:(> (length$ ?inputs) 0))
		(output ?output) (points ?machine-points))

  =>
  (retract ?uf)
  (printout t "Updating " ?m "|" ?mtype " load from " ?old-lw " to " ?new-lw crlf)
  (bind ?new-lw-size (length$ ?new-lw))
  
  (if (= ?new-lw-size (length$ ?inputs))
   then ; production at this machine is complete
    (modify ?mf (state IDLE) (loaded-with)  (desired-lights GREEN-ON)
  	    (productions (+ ?p 1)))
    (modify ?gf (points (+ ?points ?machine-points)))
    ;(modify ?pf (state ?output))
    (delayed-do-for-all-facts ((?puck puck)) (member$ ?puck:id ?new-lw)
      (if (member$ ?puck:id ?old-lw)
        then (modify ?puck (state CONSUMED))
        else (modify ?puck (state ?output))
      )
    )
  )
  (if (= ?new-lw-size 0)
   then ; all pucks have been removed
    (modify ?mf (state IDLE) (loaded-with)  (desired-lights GREEN-ON))
  )
  (if (> ?new-lw-size 0)
   then ; partial input, more pucks required to complete
    (modify ?mf (state WAITING) (loaded-with ?new-lw) (desired-lights YELLOW-ON))
  )
) 


