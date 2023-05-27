# Client (tbootui) and server (tbootd) communication

1. tbootd starts and creates the `/tmp/tinyboot.sock` socket
1. tbootui starts, connects to the tinyboot socket, and spawns multiple client
   threads on each device a user can interact with (display TTY, serial TTY,
   etc.)
1. tbootui starts streaming boot options from tbootd, then lets each tbootui
   client thread know about the new options
1. if a user interaction occurs before boot timeout, a tbootui client thread is
   able to make a selection (and optionally edit kernel params) and lets the
   main tbootui thread know that a selection has been made
1. the main tbootui thread stops streaming boot options and sends a request to
   boot the selected boot option
1. if booting is successful, we are done; if not successful, the main tbootui
   thread gets the boot error message from tbootd and starts streaming boot
   options again
