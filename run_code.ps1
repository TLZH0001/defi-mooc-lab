#!/bin/bash
sudo docker container prune --force
sudo docker image rm defi-mooc-lab2
sudo docker build -t defi-mooc-lab2 .
sudo docker run -e ALCHE_API="https://eth-mainnet.g.alchemy.com/v2/EgjaZ4OOPgKBbpt9lwUI8srv2jvdqCye" -it defi-mooc-lab2 npm test
