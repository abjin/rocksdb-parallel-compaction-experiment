wget -O /tmp/netdata-kickstart.sh https://my-netdata.io/kickstart.sh && sh /tmp/netdata-kickstart.sh

sudo apt-get update
sudo apt-get install libgflags-dev
sudo apt install make
sudo apt-get install --reinstall g++
sudo apt-get install libsnappy-dev

git clone https://github.com/facebook/rocksdb
cd rocksdb

make -j 4 ./db_bench