# Client (tbootui) and server (tbootd) communication

1. tbootd starts and creates the `/tmp/tinyboot/tboot.sock` socket
1. tbootui is started on at least one input device (display TTY, serial TTY,
   etc.), connects to the tinyboot socket
1. tbootui starts streaming boot options and other data from tbootd
1. if a user interaction occurs before boot timeout, tbootui is able to make a
   selection (and optionally edit kernel params) and lets tbootd know that a
   selection has been made
1. tbootd attempts to boot into the selected option
