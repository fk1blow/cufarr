# testing inside vm

## 1. Install it
brew install --cask multipass

## 2. Create an Ubuntu 24.04 VM (the tutorial uses 24.04 too)
multipass launch 24.04 --name brig --cpus 2 --memory 4G --disk 20G

## 3. Open a shell inside it
multipass shell brig
