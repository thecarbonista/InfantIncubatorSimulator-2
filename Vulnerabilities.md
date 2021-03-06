# Infant Incubator Simulator: Vulnerabilities Description

IMPORTANT: Please ensure the python-dotenv and Pycryptodome libraries are installed prior to running SampleNetworkServer.py.

## Exposure of Logon Password and Token: Attack against Confidentiality

The socket sendto call within the ``authenticate`` function: ``s.sendto(b"AUTH %s" % pw, ("127.0.0.1", p))`` submits the password alongside the AUTH command in plaintext. This risk has not been mitigated as no means of encryption can be found at the transport (eg. TLS) or network (eg. IPSec) layers. Using this information, we craft a test case in which traffic captured by tcpdump on ports 23456 and 23457 from the loopback interface is parsed using awk and packets containing the plaintext password are writtened to ``discovered.txt``. An attacker may simply intercept the credentials submitted as part of the authentication process, attempt logon themselves, and then issue (potentially dangerous) commands to the server using a valid token conferred to them.

Or, an attacker may sniff the token over the wire after authentication has taken place and use it to issue unauthorized commands against the unwitting user. In fact, the plaintext token may also be used to conduct a denial-of-service attack if it is sniffed and submitted alongside a LOGOUT request to the server each time.

As part of layered security approach, we would likely isolate the server in a network segment such that it is reachable only by the workstations in the neonatal intensive care unit and reinforced by NAC (eg. MAC address whitelisting).

```
sudo tcpdump -i lo -nnX dst port '(23456 or 23457)' | awk '{ if (/!Q#E%T&U8i6y4r2/ || /AUTH/ || /.*0x0030:.*/) { print > "discovered.txt" } else { print > "not-found.txt" } }' &
sleep 30

if grep -q "!Q#E%T&U8i6y4r2" discovered.txt; then
    echo plaintext password found
else
    echo plaintext password not found
fi
```

The encryption scheme we have implemented harnesses the scrypt PBKDF and AES 128-bit in EAX mode of operation to ensure perfect forward secrecy and reduce the risk of key compromise. Replay attacks can be mitigated by invalidating (ie. randomizing) either (1) the client-generated nonce value used for AES encryption or (2) salt value needed to recover the session key in the scrypt function--we elected to override the latter. If the session key is discarded, decryption fails due to incorrect key length or results in some plaintext value which fails the MAC verification check.

Considerations:
- Because the server has been configured to intake encrypted data, sending plaintext messages via ``nc -u 127.0.0.1 23456``, for example, will likely result in parsing errors.

### Before encryption-in-transit:

![alt text](https://github.com/kevinkenzhao/InfantIncubatorSimulator/blob/main/plaintext_traffic.PNG?raw=true)

### After encryption-in-transit:

![alt text](https://github.com/kevinkenzhao/InfantIncubatorSimulator/blob/main/encrypted_traffic.PNG?raw=true)

### Encryption Diagram

![alt text](https://github.com/kevinkenzhao/InfantIncubatorSimulator/blob/main/encryption-diagram.png?raw=true)

_Nota bene_: encrypted traffic is considerably larger than its plaintext counterpart, primarily owing to the use of the delimiter "CS-GY6803" to properly parse the nonce, encrypted message, AES tag, PBKDF salt, and transmit mode (to determine whether the existing salt value should be used or a new one should be generated) when it arrives at the recipient's socket.


## Attacks against Integrity

### Modification of Commands

A client may issue a command alongside the token conferred upon them to the server, but since the command is neither encrypted nor checked for truthfulness, it may be seamlessly interchanged by an attacker without detection. Therefore, an innocuous command like: 

``s.sendto(b"%s;GET_TEMP" % tok, ("127.0.0.1", p))``

may arrive to the server as:

``([A-Za-z0-9]{16});UPDATE_TEMP``

We devised the following scenario in which a socat server proxies the connection between the user and SampleNetworkServer, rewriting the "GET_TEMP" command to "UPDATE_TEMP," and vice versa:

```
sudo apt-get install socat
kill -9 $(sudo lsof -t -i:23456)
kill -9 $(sudo lsof -t -i:5557)
sleep 3 #allot time for termination of above processes 

python3 SampleNetworkServer.py & #start server in the background
sleep 1
socat -u tcp-l:5557,fork system:./modify.sh | nc -u 127.0.0.1 23456 & #start socat with script that rewrites commands; modified commands are piped to port 23456
sleep 1
token="$(echo "AUTH !Q#E%T&U8i6y4r2w" | nc -w 3 -u 127.0.0.1 23456)" #terminate netcat after three seconds
echo "the token: ${token}"
sleep 1
echo "issuing UPDATE_TEMP command to server..."
UPDATE_CMD="${token};UPDATE_TEMP"
echo "full command: ${UPDATE_CMD}"
echo "${UPDATE_CMD}" | nc -w 3 127.0.0.1 5557
```
**modify.sh**
```
#!/bin/bash
read MESSAGE
if grep -q "UPDATE" <<< "$MESSAGE"
then
	var=$(echo "$MESSAGE" | awk '{ sub(/UPDATE/,"GET"); print }')
	echo $var
elif grep -q "GET" <<< "$MESSAGE"
then
	var=$(echo "$MESSAGE" | awk '{ sub(/GET/,"UDPATE"); print }')
	echo $var
else
	echo $MESSAGE
fi
```

The success of the attack rests on commands being transmitted in plaintext and the absence of a mechanism to verify that the intended command was not modified in-transit. We mitigate the risk of this attack by taking the has of the plaintext command before it is encrypted and sending both the ciphertext and tag to the recipient, where it is independently verified. 

## Lack of Identity

The current prototype uses a password and 16-character psuedorandom token with character set (^[A-Za-z0-9]{16}$) for its authentication processes. However, it does not have means for managing the identity of those successful logon attempts. This is less of an issue if we assume that only one nurse at a hospital should monitor the incubator and know the password. However, nurses carry a myriad of responsibilities and work in shifts, thus multiple nurses would access the remote interface. Should any of the nurses commit an act of malevolence, the organization has the ability to attribute/account for the damages.

Therefore, the authentication scheme has been amended to require users to supply a non-generic username along with their password in the form: ``AUTH USERNAME PASSWORD``. Passwords will be digested with the X algorithm, and stored/retrieved from a ``env.example`` file stored on the server and secured with root privileges. 

## Duplicate Tokens

Suppose Eve intercepts an ``AUTH`` communication by Alice to the ``SampleNetworkServer`` and discovers the command ``AUTH !Q#E%T&U8i6y4r2w`` in the application layer of the captured packets. We assume that the packets are unencrypted, though encrypted packets would work all the same. Using this information, we crafted a test case which generates and submits a fast and continuous stream of authentication requests to ``SampleNetworkServer``. Performed at scale, this attack could lead to token exhaustion (if unique tokens in ``tokens[]`` is enforced), duplicate tokens in ``tokens[]``, or eventually, a program crash due to system resource exhaustion. _If duplicate tokens exist, a user that performs a LOGOUT operation using their token has not invalidated their token until they have perform the LOGOUT operations for the number of token occurences_.

Although there is an infinitesimal chance of distributing a token which already exists in the list ``tokens[]`` given the sample space of (26 capital letters + 26 lowercase letters + 10 digits)^16, there is no mechanism to prevent that situation from occurring. Therefore, a check for whether a psuedorandomly generated token exists in ``tokens[]`` before appending it to the list should be implemented--if it does, generate a new one.

```
while True:
    gen_token = ''.join(random.choice(string.ascii_uppercase + string.ascii_lowercase + string.digits) for _ in range(16))
    if gen_token not in self.tokens:
        break
self.tokens.append(gen_token) 
```

To mitigate the risk of a DoS scenario as a result of perpetual authentication requests, we increased the token size to 64-characters. Moreover, we implemented the notion of identity so that in successive iterations of the product, rate-limiting control based on the number of successful requests by a specific username can be instituted.

```
#!/usr/bin/bash

while :
do
	echo "AUTH !Q#E%T&U8i6y4r2w" | nc -u 127.0.0.1 23456 &
	printf "\n"
	sleep 1
	pid=$!
	( kill -TERM $pid ) 2>&1
done
```

## Replay Attack

Although encryption and hashing may prevent an attacker from learning meaningful information from packet traffic or passing modified content as genuine, they do not prevent the replay of captured UDP traffic. We have elected to accept the risk of a replay attack on SimpleNetworkServer as the responses from the server cannot be decipher by an attacker, and the set of commands that may be submitted to the server cannot impart harm on a baby. However, DoS attacks, such as replay or token exhaustion attacks, will threaten our ability to receive accurate and timely temperature readings. To this end, we plan to leverage sequence numbers in the next product iteration. These numbers would be concatenated with the plaintext message, and a hash of the resulting string will be captured before it is encrypted with AES-EAX.

## Dead Code: addInfant()

The addInfant() function accounts for energy offsets given the placement of a baby within an incubator. However, that function is not called in any running function! Therefore, we added the function to the Simulator class as it is reasonable to assume that an incubator will be occupied:

```
class Simulator (threading.Thread) :
    
    def __init__ (self, infant, incubator, roomTemp, timeStep, sleepTime) : 
        #infWeight, infLength, infTemp, infant, incWidth, incDepth, incHeight, incTemp, roomTemp, timeStep) :

        threading.Thread.__init__(self, daemon = True)
        self.infant = infant #Human(infWeight, infLength, infTemp)
        self.incubator = incubator #Incubator(incWidth, incDepth, incHeight, incTemp, roomTemp)
        self.roomTemperature = roomTemp
        self.iteration = 0
        self.timeStep = timeStep
        self.sleepTime = sleepTime
        self.incubator.addInfant(self.infant)
```

## Session Expiry

Unless the SampleNetworkServer is restarted, all previously issued access tokens are valid until the user explicitly invalidates them by issuing the LOGOUT command along with their access token(s). However, a nurse may forget or refuse to log out of the system at the conclusion of their shift. This results in a lack of forward secrecy as an attacker who has learned of a token from _X_ days/months/years ago may leverage it indefinitely.

One approach to mitigate this issue is to perform a server-side check of a token submitted alongside a command to ascertain that the difference between CURRENT_TIME and TIME is less than or equal to the MAX_AGE (defined by the system designer). If this statement evaluates to true, the token in question is removed from self.tokens[] and the user is prompted to re-authenticate.

We have implemented a token validity check in the form of a conditional statement:
```
if time.time() - self.tokens[gen_token] > 43200:
    nonce, encrypted_msg, tag = self.AES_encrypt(session_key, b"Expired Token\n")
    full_msg = nonce + b" " + encrypted_msg + b" " + tag
    self.serverSocket.sendto(full_msg, addr)   
```

and re-implemented _self.tokens_ as a dictionary instead a list structure, allowing us to append randomly generated tokens as keys and update their corresponding values with the time of generation. By storing this additional value, we are able to perform validity checks on whether the token in question has exceeded the max age of 12 hours.

## Password Storage: Adherence to Best Practice

Passwords should, at minimum, not be hard-coded into the SampleNetworkServer.py file. In this example, we will hash the plaintext password using the blake2b keyed hashing algorithm and store the result in a .env file through an entry of the form: ``USERNAME = '256_BIT_KEYED_HASH'``. The hash value will be retrieved (during the authentication process) using Python's ``dotenv`` module. For the purpose of demonstration, we will precompute the hash for plaintext password ``!Q#E%T&U8i6y4r2w`` using the key ``dUX&ggW4E7=PtG/PH6d`` and store the result in the form ``defaultuser0 = '7a47576b041f70eafcf9e74e579bc87c'`` in the .env file. Similarly, the key to the blake2b function will be stored as an entry: ``BLAKE_KEY = 'dUX&ggW4E7=PtG/PH6d'``.

The following code generates the 256-bit keyed hash of defaultuser0's password for storage:

```
h = blake2b(key=b'dUX&ggW4E7=PtG/PH6d', digest_size=16)
j = b'!Q#E%T&U8i6y4r2w'
h.update(j)
h.hexdigest()
```
