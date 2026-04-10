#!/bin/bash

if [ ! -d "../euler-interfaces" ]; then
  cd .. && git clone https://github.com/euler-xyz/euler-interfaces.git && cd warren-deploy
else
  cd ../euler-interfaces && git pull && cd ../warren-deploy
fi

forge install
