## Tuya WebRTC Demo
Tuya Smart WebRTC Demo provides examples of using iOS App to connect to an IPC through WebRTC. The Demo shows the entire process of App connecting IPC through WebRTC, including: interface, MQTT connection, SDP interaction and more.

The Demo mainly includes the following functions:
* Obtain token, obtain MQTT login information and device-related WebRTC information and more.

* MQTT login, subscription, message sending and receiving and more.

* WebRTC, SDP interaction and more.

* Browse the video of the camera through the app and make voice calls with the camera.

## Procedure

1. Obtain the `clientid` through the IoT account.

2. Authorize through the URL below and get the authorization code.

    1). Fill in the clientid and user account, and then run the following link in the browser to authorize.
    https://openapi-cn.wgine.com/login/open/tuya/login/v1/index.html?client_id=clientid (clientId obtained in step 1) clientid&redirect_uri=https://www.example.com/ auth&state=1234&username=(user account)&app_schema=tuyasmart&is_dynamic=true

    2). After the authorization is successful, the following address will be returned:
    https://www.example.com/auth?code=xxxxxxxxxxxxxxxxxxxx&state=1234&platform_url=https://openapi-cn.wgine.com
    The code in the address is the authorization code.
    
3. Obtain the `DID` and `localKey` that need to access the camera through the App or other methods.

4. Modify the corresponding parameters in the `ARDAppClient.m` file in Demo:
5. 
   clientId_ = Modify it as the `clientid` obtained in step 1
   
   secret_   = Modify it as the  `secret` obtained in step 1
   
   authCode_ = Modify it as the authorization code obtained in step 2
   
   deviceId_ = Modify it as the device ID obtained in step 3
   
   localKey_ = Modify it as the LocalKey of the device obtained in step 3
   
5. After the parameter modification is completed, run Demo for debugging.

## Main process of the Demo

1. Get the token.
    ```
      -(BOOL)getTokenWithClientId:(NSString*)clientId secret:(NSString*)secret code:(NSString*)code
    ```
      The interface will return important information such as  accessToken, UID.
      
2. Obtain MQTT related information.
    ```
      -(BOOL)getMQTTConfig:(NSString*)clientId secret:(NSString*)secret access_token:(NSString*)access_token
      ```
      The returned information is mainly used to log in to the MQTT server. It mainly contains information such as server address, port, user name, and password.
      
3. Obtain the device WebRTC related configuration.
    ```
      -(BOOL)getRtcConfig:(NSString*)clientId secret:(NSString*)secret access_token:(NSString*)access_token deviceid:(NSString*)did
    ```
4. Connect to the MQTT server.
  
5. After the MQTT connection is successful, subscribe to the corresponding topic. Refer to Demo for the definition of the topic.
  
6. After the subscription is successful, the peerconnection is started locally, and then SDP interactive work can be performed through MQTT.
  
7. After the interaction is successful, you can see the video of the camera.
