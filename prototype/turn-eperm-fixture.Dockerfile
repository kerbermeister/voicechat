ARG TURN_BUILD_IMAGE
ARG TURN_IMAGE
FROM ${TURN_BUILD_IMAGE} AS fault
COPY turn_eperm_fault.c /tmp/turn_eperm_fault.c
RUN cc -Wall -Wextra -Werror -shared -fPIC -pthread /tmp/turn_eperm_fault.c -ldl -o /tmp/turn-eperm-fault.so

FROM ${TURN_IMAGE}
USER root
COPY --from=fault /tmp/turn-eperm-fault.so /opt/turn-eperm-fault.so
# cp keeps identical ELF bytes without the file capability, so the test loader
# honours LD_PRELOAD. The actual production binary and its capability stay intact.
RUN cp /usr/bin/turnserver /opt/turnserver-under-test
USER 10001:10001
ENV LD_PRELOAD=/opt/turn-eperm-fault.so
ENTRYPOINT ["/opt/turnserver-under-test"]
