require 'active_support/core_ext/date/calculations'
require 'active_support/core_ext/numeric/time'

class ShipstationClient
  class ResponseError < StandardError; end

  class << self
    def request(method, path, options)
      response = Unirest.send method, "https://shipstation.p.mashape.com/#{path}", options
      return response if response.code == 200

      raise ResponseError, "#{response.code}, API error: #{response.body.inspect}"
    end
  end
end

class ShipStationApp < EndpointBase::Sinatra::Base
  set :public_folder, 'public'
  set :logging, true

  Honeybadger.configure do |config|
    config.api_key = ENV['HONEYBADGER_KEY']
    config.environment_name = ENV['RACK_ENV']
  end

  error ShipstationClient::ResponseError do
    result 500, env['sinatra.error'].message
  end

  # REST API doc https://www.mashape.com/shipstation/shipstation

  post '/add_shipment' do
    # Shipstation wants orders and then it creates shipments. This integration assumes the
    # shipments are already split and will just create "orders" that are identical to the
    # storefront concept of a shipment.

    order = populate_order(@payload[:shipment])
    options = {
      headers: ship_headers.merge("content-type" => "application/json"),
      parameters: order.to_json
    }

    response = ShipstationClient.request :post, "Orders/CreateOrder", options
    result 200, "Shipment transmitted to ShipStation: #{response.body["orderId"]}"
  end

  # Error response.body examples:
  #
  #   400
  #   => {"Message"=>"The request is invalid.",
  #   "ModelState"=>
  #    {"apiOrder.orderNumber"=>["The orderNumber field is required."],
  #     "apiOrder.orderDate"=>["The orderDate field is required."],
  #     "apiOrder.orderStatus"=>["The orderStatus field is required."],
  #     "apiOrder.billTo"=>["The billTo field is required."],
  #     "apiOrder.shipTo"=>["The shipTo field is required."]}}
  #
  #    401
  #    => {"message"=>
  #    "Missing Mashape application key. Go to https://www.mashape.com to get your key."}
  #
  post '/update_shipment' do
    @shipment = @payload[:shipment]

    # NOP if shipment has been already shipped
    # possibly to avoid infinite loops with update_shipment <-> get_shipments
    if @shipment[:status] == "shipped"
      return result 200, "Can't update Order when status is #{ @shipment[:status] }"
    end

    response = ShipstationClient.request :get, "Orders/List?orderNumber=#{@shipment[:id]}", headers: ship_headers

    orders = response.body["orders"]
    if orders && order = orders.first

      populated_order = populate_order(@payload[:shipment])
      populated_order.merge! "orderKey" => order["orderKey"]

      options = {
        headers: ship_headers.merge("content-type" => "application/json"),
        parameters: populated_order.to_json
      }

      response = ShipstationClient.request :post, "Orders/CreateOrder", options
      result 200, "Shipment update transmitted in ShipStation: #{order["orderId"]}"
    else
      result 200, "Order #{ @shipment[:id] } not found in ShipStation."
    end
  end

  post '/get_shipments' do
    # ShipStation appears to be recording their timestamps in local (PST) time but storing that timestamp
    # as UTC (so it's basically 7-8 hours off the correct time (depending on daylight savings). To compensate
    # for this the timestamp we use for "since" should be adjusted accordingly.
    zone = "Pacific Time (US & Canada)"
    since_time = Time.parse(@config[:since]).in_time_zone(zone)
    since_date = "#{since_time.year}-#{since_time.month}-#{since_time.day}"

    query_string = "page=1&pageSize=500&shipdatestart=#{since_date}"
    response = ShipstationClient.request :get, "Shipments/List?#{query_string}", headers: ship_headers

    @kount = 0

    response.body["shipments"].each do |shipment|
      # ShipStation cannot give us shipments based on time (only date) so we need to filter the list of
      # shipments down further using the timestamp provided
      #
      # Need to parse value returned from SS as PT
      next unless ActiveSupport::TimeZone[zone].parse(shipment["createDate"]) > since_time

      @kount += 1
      shipTo = shipment["shipTo"]

      add_object :shipment, {
        id: shipment["orderNumber"],
        tracking: shipment["trackingNumber"],
        shipstation_id: shipment["shipmentId"],
        status: "shipped",
        shipping_address: {
          firstname: shipTo["name"].split(" ").first,
          lastname:  shipTo["name"].split(" ").last,
          address1:  shipTo["street1"],
          address2:  shipTo["street2"],
          zipcode:   shipTo["postalCode"],
          city:      shipTo["city"],
          state:     shipTo["state"],
          country:   shipTo["country"],
          phone:     shipTo["phone"]
        },
        shipstation: shipment
      }
    end

    if @kount > 0
      # Tell Wombat to use the current time as the 'high watermark' the next time it checks
      add_parameter 'since', Time.now.utc.iso8601

      set_summary "Retrieved #{@kount} shipments from ShipStation"
    end

    result 200
  end

  private

  def map_carrier(carrier_name)
    response = ShipstationClient.request :get, "Carriers", headers: ship_headers

    response.body.each do |carrier|
      return carrier["code"] if carrier["name"] == carrier_name
    end

    raise "There is no carrier named '#{carrier_name}' configured with this ShipStation account"
  end

  def map_service(carrier_code, service_name)
    response = ShipstationClient.request :get, "Carriers/ListServices?carrierCode=#{carrier_code}", headers: ship_headers

    response.body.each do |service|
      return service["code"] if service["name"] == service_name
    end

    raise "There is no service named '#{service_name}' associated with the carrier_code of '#{carrier_code}'"
  end
  
  def map_package(carrier_code, package_name)
    response = ShipstationClient.request :get, "Carriers/ListPackages?carrierCode=#{carrier_code}", headers: ship_headers

    response.body.each do |package|
      return package["code"] if package["name"] == package_name
    end

    raise "There is no package named '#{package_name}' associated with the carrier_code of '#{carrier_code}'"
  end

  def populate_order(shipment)
    order = {
      "customerEmail" => shipment[:email],
      "customerUsername" => shipment[:email],
      "orderNumber" => shipment[:id], #required
      "orderDate" => shipment[:created_at] || Time.now,
      "paymentDate" => shipment[:created_at] || Time.now,
      "orderStatus" => map_status(shipment[:status]), #required: hold, canceled, awaiting_shipment
      "shipTo" => populate_address(shipment[:shipping_address]), #required (see populate_address for details)
      "billTo" => populate_address(shipment[:billing_address]) || populate_address(shipment[:shipping_address]),
      "shippingAmount" => shipment[:shipping_amount].to_f.to_s,
      "customerNotes" => shipment[:delivery_instructions],
      "internalNotes" => shipment[:internal_notes],
      "gift" => shipment[:is_gift],
      "packageCode" => 'package',
      "advancedOptions" => populate_advanced(shipment),
      "items" => populate_items(shipment[:items])
    }

    if shipment[:amount_paid]
      order["amountPaid"] = shipment[:amount_paid]
    end

    if shipment[:requested_shipping_service]
      order["requestedShippingService"] = shipment[:requested_shipping_service]
    else
      carrier_code = map_carrier(shipment[:shipping_carrier]) #
      order["carrierCode"] = carrier_code
      order["serviceCode"] = map_service(carrier_code, shipment[:shipping_method])
      order["packageCode"] = map_package(carrier_code, shipment[:package]) if shipment[:package]
    end

    order
  end

  def populate_advanced(shipment)
    advanced = {
      "storeId" => @config[:shipstation_store_id],
      "customfield1" => shipment[:custom_field_1],
      "customfield2" => shipment[:custom_field_2],
      "customfield3" => shipment[:custom_field_3],
    }

    if shipment[:contains_alcohol]
      advanced["containsAlcohol"] = shipment[:contains_alcohol]
    end

    if shipment[:saturday_delivery]
      advanced["saturdayDelivery"] = shipment[:saturday_delivery]
    end

    if shipment[:non_machinable]
      advanced["nonMachinable"] = shipment[:non_machinable]
    end

    advanced
  end

  def populate_items(line_items)
    return if line_items.nil?
    line_items.map do |item|
      {
        "lineItemKey" => nil,
        "sku" => item[:product_id],
        "name" => item[:name],
        "imageUrl" => item[:image_url],
        "quantity" => item[:quantity],
        "unitPrice" => item[:price]
      }
    end
  end

  def populate_address(address)
    return if address.nil? || address.empty?
    {
      :name => address[:firstname] + " " + address[:lastname], #required
      :street1 => address[:address1], #required
      :street2 => address[:address2],
      :street3 => address[:address3],
      :city => address[:city], #required
      :state => address[:state], #required
      :postalCode => address[:zipcode], #required
      :country => address[:country], #required
      :phone => address[:phone]
    }
  end

  def map_status(status)
    case status
    when 'hold'
      'on_hold'
    when '/cancell?ed/'
      'canceled'
    else
      'awaiting_shipment'
    end
  end

  def ship_headers
    {
      "Authorization" => "Basic #{@config[:authorization]}",
      "X-Mashape-Key" => @config[:mashape_key]
    }
  end
end
