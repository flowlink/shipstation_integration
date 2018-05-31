# ShipStation Integration

This is a fully hosted and supported integration for use with the [FlowLink](http://flowlink.io/) product. With this integration you can perform the following functions:

* Send shipments to ShipStation
* Update shipments in ShipStation
* Retrieve shipments that have been shipped from ShipStation

# About FlowLink

[FlowLink](http://flowlink.io/) allows you to connect to your own custom integrations.
Feel free to modify the source code and host your own version of the integration
or better yet, help to make the official integration better by submitting a pull request!

This integration is 100% open source an licensed under the terms of the New BSD License.

![FlowLink Logo](http://flowlink.io/wp-content/uploads/logo-1.png)

### Run Locally
```sh
$ docker rm -f shipstation-integration-container
$ docker build -t shipstation-integration .
$ docker run -t -e VIRTUAL_HOST=shipstation_integration.flowlink.io -e RAILS_ENV=development -v $PWD:/app -p 3001:5000 --name shipstation-integration-container shipstation-integration
```

## Connection Parameters

The following parameters must be setup within [FlowLink](http://flowlink.io/):

| Name | Value |
| :----| :-----|
| shipstation_store_id | Store ID - possibly workflow param if multiple stores used |
| key | API Access Key (required) |
| secret | API Access Secret (required) |

### Possible Config Options
* __page__ => Used for pagination on the GET_SHIPMENTS workflow. Should be initially set to 1, then it will automatically update as needed
* __since__ => Used on the GET_SHIPMENTS workflow
* __shipstation_store_id__ => Used on the ADD_SHIPMENT and UPDATE_SHIPMENT workflows (maybe workflow param??)
    - To retrieve the store ID, navigate to the admin area of ShipStation and select __Selling Channels__ then __Store Setup__. Click __Edit__ on the store you'd like to use. The ID will be the set of numbers at end of the URL in your browser window. They will immediately follow __/stores/__.
    - For example: https://ss5.shipstation.com/#/settings/stores/189338 - The store ID would be 189338
* __key__ => Used on ALL workflows
* __secret__ => Used on ALL workflows
* __authorization__ => Used on ALL workflows (NOTE: Only used for Legacy clients - key/secret not needed if authorization is used. Shipstation may no longer support this API access)
* __x_partner__ => Used on ALL workflows (NOTE: Most likely only used for Legacy clients as well. Shipstation may no longer support this API access)
