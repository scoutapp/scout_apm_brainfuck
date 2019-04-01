Scout APM BrainFuck Agent
=========================

Find out more at our announcement post:
[https://scoutapp.com/blog/announcing-brainfuck-monitoring-for-scout-apm](https://scoutapp.com/blog/announcing-brainfuck-monitoring-for-scout-apm)

Acknowledgements
----------------

Thank you to Shinichiro Hamaji [@shinh](https://github.com/shinh) for the excellent BrainFuck interpreter we modified.
See his very cool [ELVM Compiler Infrastructure](https://github.com/shinh/elvm/) project to compile C programs into working BrainFuck code (among other EsoLang targets).

Setup
-------

Prereq: Ruby to run the BF Interpreter.

1. [Sign up]( https://scoutapm.com/users/sign_up?utm_source=github&utm_campaign=april_1_2019) for an free trial account
2. Get your Org Key
3. Download the Core Agent binary
   ```
   # OSX:
   wget https://s3-us-west-1.amazonaws.com/scout-public-downloads/apm_core_agent/release/core-agent-latest-x86_64-apple-darwin.tgz

   # Linux:
   wget https://s3-us-west-1.amazonaws.com/scout-public-downloads/apm_core_agent/release/core-agent-latest-x86_64-unknown-linux-gnu.tgz

   # For either one, untar it:
   tar xvzf core-agent-latest.....tgz
   ```
4. Start the Core Agent
    ```
    ./core-agent start
    ```
5. In another window, setup your environment variables:
   ```
   # Your Application Name
   export SCOUT_NAME=unicorn

   # Your Org Key (
   export SCOUT_KEY="fXU8f....Vi3A"
   ```
6. And run your BF app!
    ```
    ruby bf.rb pack/hello.c.eir.bf
    ```

Examples
--------

There are a handful of example BF apps in the pack.tgz file.

```
# Unpack the examples into pack/:

tar xvzf pack.tgz

# Calendar
echo 2018 03 | bf.rb pack/cal.bf

# Hello World
ruby bf.rb pack/hello.c.eir.bf

# FizzBuzz
ruby bf.rb pack/fizzbuzz.c.eir.bf
```

Configuration
-------------

```
SCOUT_NAME - Required, the name of the application that appears in the ScoutAPM UI
SCOUT_KEY - Required, the Org key for your organization. Can be found in the Org settings page
SCOUT_SOCKET_PATH - Optional, for if you run the core agent outside of the same directory as the BF interpreter.
```

Limitations
-----------

The trace is sent only after the interpreter is finished, and not while it is in progress. This means you've gotta wait out FizzBuzz (several minutes) and other long applications.

