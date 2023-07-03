#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

#Machine should have /dev/tpm0 or /dev/tpmrm0 device
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

[ -n "$DOCKERFILE_VERIFIER" ] || DOCKERFILE_VERIFIER=Dockerfile.upstream.c9s
[ -n "$DOCKERFILE_REGISTRAR" ] || DOCKERFILE_REGISTRAR=Dockerfile.upstream.c9s
[ -n "$DOCKERFILE_AGENT" ] || DOCKERFILE_AGENT=Dockerfile.upstream.c9s
[ -n "$DOCKERFILE_TENANT" ] || DOCKERFILE_TENANT=Dockerfile.upstream.c9s


rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # update /etc/keylime.conf
        limeBackupConfig
        CONT_NETWORK_NAME="container_network"
        IP_VERIFIER="172.18.0.4"
        IP_REGISTRAR="172.18.0.8"
        IP_AGENT="172.18.0.12"
        IP_TENANT="172.18.0.16"
        #create network for containers
        rlRun "limeconCreateNetwork ${CONT_NETWORK_NAME} 172.18.0.0/16"

        #prepare verifier container
        rlRun "limeUpdateConf verifier ip $IP_VERIFIER"
        rlRun "limeUpdateConf verifier registrar_ip $IP_REGISTRAR"
        #for log purposes, when agent fail, we need see verifier log, that attestation failed
        rlRun "limeUpdateConf verifier log_destination stream"

        # prepare registrar container
        rlRun "limeUpdateConf registrar ip $IP_REGISTRAR"

        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant verifier_ip $IP_VERIFIER"
        rlRun "limeUpdateConf tenant registrar_ip $IP_REGISTRAR"

        #need to setup configuration files

        #build verifier container
        TAG_VERIFIER="verifier_image"
        rlRun "limeconPrepareImage ${limeLibraryDir}/${DOCKERFILE_VERIFIER} ${TAG_VERIFIER}"

        #build registrar container
        TAG_REGISTRAR="registrar_image"
        rlRun "limeconPrepareImage ${limeLibraryDir}/${DOCKERFILE_REGISTRAR} ${TAG_REGISTRAR}"

        #build tenant container
        TAG_TENANT="tenant_image"
        rlRun "limeconPrepareImage ${limeLibraryDir}/${DOCKERFILE_TENANT} ${TAG_TENANT}"

        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            # start ima emulator
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi
        sleep 5

        #mandatory for access agent containers to tpm
        rlRun "chmod o+rw /dev/tpmrm0"

        #run verifier container
        CONT_VERIFIER="verifier_container"
        rlRun "limeconRunVerifier $CONT_VERIFIER $TAG_VERIFIER $IP_VERIFIER $CONT_NETWORK_NAME"
        rlRun "limeWaitForVerifier 8881 $IP_VERIFIER"
        #wait for generating of certs
        sleep 5
        rlRun "podman cp $CONT_VERIFIER:/var/lib/keylime/cv_ca/ ."

        #run registrar container
        CONT_REGISTRAR="registrar_container"
        rlRun "limeconRunRegistrar $CONT_REGISTRAR $TAG_REGISTRAR $IP_REGISTRAR $CONT_NETWORK_NAME"
        rlRun "limeWaitForRegistrar 8891 $IP_REGISTRAR"

        CONT_TENANT="tenant_container"
        # define limeconKeylimeTenantCmd so that the keylime container can be used by limeWaitForAgentStatus etc.
        limeconKeylimeTenantCmd="--name $CONT_TENANT --net $CONT_NETWORK_NAME --ip $IP_TENANT localhost/$TAG_TENANT"

        #setup of agent
        TAG_AGENT="agent_image"
        CONT_AGENT="agent_container"
        rlRun "limeconPrepareImage ${limeLibraryDir}/${DOCKERFILE_AGENT} ${TAG_AGENT}"
        rlRun "limeUpdateConf agent registrar_ip '\"$IP_REGISTRAR\"'"
        rlRun "limeconPrepareAgentConfdir $AGENT_ID $IP_AGENT confdir_$CONT_AGENT"

        # create some scripts
        TESTDIR=$(limeCreateTestDir)
        rlRun "echo -e '#!/bin/bash\necho This is good-script1' > $TESTDIR/good-script1.sh && chmod a+x $TESTDIR/good-script1.sh"
        rlRun "echo -e '#!/bin/bash\necho This is good-script2' > $TESTDIR/good-script2.sh && chmod a+x $TESTDIR/good-script2.sh"
        # create allowlist and excludelist
        rlRun "limeCreateTestPolicy ${TESTDIR}/*"
        limeconTenantVolume="--volume $PWD/:/workdir/:z"

        rlRun "limeconRunAgent $CONT_AGENT $TAG_AGENT $IP_AGENT $CONT_NETWORK_NAME $PWD/confdir_$CONT_AGENT $TESTDIR"
        rlRun -s "limeWaitForAgentRegistration $AGENT_ID"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        rlRun "limeKeylimeTenant -v $IP_VERIFIER  -t $IP_AGENT -u $AGENT_ID --runtime-policy /workdir/policy.json -f /etc/hosts -c add"
        rlRun -s "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "limeKeylimeTenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" "$rlRun_LOG" -E
    rlPhaseEnd

    rlPhaseStartTest "Running allowed scripts should not affect attestation"
        rlRun "${TESTDIR}/good-script1.sh"
        rlRun "${TESTDIR}/good-script2.sh"
        rlRun "tail /sys/kernel/security/ima/ascii_runtime_measurements | grep good-script1.sh"
        rlRun "tail /sys/kernel/security/ima/ascii_runtime_measurements | grep good-script2.sh"
        rlRun "sleep 5"
        rlRun -s "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/bad-script.sh && chmod a+x $TESTDIR/bad-script.sh"
        rlRun "$TESTDIR/bad-script.sh"
        rlRun "sleep 5"
        rlRun "podman logs verifier_container | grep \"keylime.verifier - WARNING - Agent d432fbb3-d2f1-4a97-9ef7-75bd81c00000 failed, stopping polling\""
        rlRun -s "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        limeconSubmitLogs
        rlRun "limeconStop registrar_container verifier_container agent_container"
        rlRun "limeconDeleteNetwork $CONT_NETWORK_NAME"
        #set tmp resource manager permission to default state
        rlRun "chmod o-rw /dev/tpmrm0"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeExtendNextExcludelist "$TESTDIR"
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd

