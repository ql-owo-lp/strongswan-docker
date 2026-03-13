sed -i 's/ip tunnel add vti10 mode vti local 1.2.3.4 remote 5.6.7.8 key 10/ip tunnel add "_v10" mode vti remote "5.6.7.8" key "10"/g' tests/run_tests.sh
sed -i 's/vti10/_v10/g' tests/run_tests.sh
