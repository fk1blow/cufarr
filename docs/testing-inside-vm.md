# testing inside vm

## 1. Install it
brew install --cask multipass

## 2. Create an Ubuntu 24.04 VM (the tutorial uses 24.04 too)
multipass launch 24.04 --name brig --cpus 2 --memory 4G --disk 20G

## 3. Open a shell inside it
multipass shell brig

## 4. Share the repo with the VM (run on Mac)
multipass mount ~/Playground/cufarr brig:/home/ubuntu/cufarr

Edit on the Mac; the VM sees the changes right away.

## 5. Install Zig inside the VM (same version as the Mac: 0.17.0)
```sh
curl -LO https://ziglang.org/download/0.17.0/zig-aarch64-linux-0.17.0.tar.xz
tar xf zig-aarch64-linux-0.17.0.tar.xz
sudo mv zig-aarch64-linux-0.17.0 /opt/zig
echo 'export PATH=/opt/zig:$PATH' >> ~/.bashrc && source ~/.bashrc
zig version
```
Use `x86_64` instead of `aarch64` on an Intel Mac (check with `uname -m` in the VM).

## 6. Build and run inside the VM
```sh
cd ~/cufarr
sudo /opt/zig/zig run src/rubber-docker/00_fork_exec.zig -- run /bin/ls
```
Plain `sudo zig` fails because root's PATH doesn't include /opt/zig, so use the full path.
Debug with `strace -f` (`sudo apt install strace`).
