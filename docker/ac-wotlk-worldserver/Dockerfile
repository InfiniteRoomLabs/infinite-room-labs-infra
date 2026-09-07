# Adds the module tree on top of the upstream worldserver image.
# The upstream runtime stage drops /azerothcore/modules; the Playerbot compose
# bind-mounts ./modules back in because mod-playerbots applies its own SQL at
# worldserver start (Playerbots.Updates.EnableDatabases=1) from that path.
# Built by scripts/wotlk-build-images.sh with the acore checkout as context.
ARG BASE
FROM ${BASE}
COPY --chown=1000:1000 modules /azerothcore/modules
