## What is provided 
In this package:
- the server code (server_test.sh)
- Original code before change to socat (server.sh)
- Client files that does the calling to the server and saving the information to their expected locations, and provide debugging messages
- Proof folder (proof) that contains videos of each section being run through (assignment, POI, and population) plus video of testcase_b 
- The images of server client communication (section 1 of assingment)
- The git log history (gitCommit)
- Client_test.sh that runs testcase_a

## Remarks about running 
Instead of trying to discover a port that doesn't exist yet, let get_port() select the port the server will use. Origination of this 
solution came from nc struggling to find the port in use (especially after you kill any straggling nc channels that can remain after ending testing).
From this get_port() will default to port 1234 by allow you to change it. It will also check that the intended port is not in use before allocation
hence if in use will choose a different port. 

There are 3 main functions of this 'server':
1. Get key assignment information of info1112 assignment 2 (as of semester 2 2026 and may need to update link beyond this timeframe)
2. Get population: which pulls population data of NSW including creating a png of population trends.
3. Get POI: can parse location name or coordinates and will use the NSW POI api to get all neighbouring POI's of a specified distance. 

## How to run 
Ideal workflow for usage is <br>
setting up the container: <br>
``docker run -it --name server -p 1234:1234 alpine sh`` <br>
check in docker desktop that the container is running correctly <br>
in a new terminal, ``docker cp server_test.sh myserver:/root/`` hence uploading our server code <br>
call the server code in the terminal that the container is running in <br>
``bash /root/server_test.sh`` <br>
Then in a separate terminal run the desired client file <br>
``./client_request_(action).sh``
e.g. ``./client_request_population.sh``
