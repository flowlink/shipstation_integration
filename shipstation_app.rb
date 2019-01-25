require 'active_support/core_ext/date/calculations'
require 'active_support/core_ext/numeric/time'
require 'base64'

Unirest.timeout(240) # generous timeout

class ShipstationClient
  class ResponseError < StandardError; end

  class << self
    def request(method, path, options)
      response = Unirest.send method, "https://ssapi.shipstation.com/#{path}", options

      return response if response.code == 200

      raise ResponseError, "#{response.code}, API error: #{response.body.inspect}"
    end
  end
end

class ShipStationApp < EndpointBase::Sinatra::Base
  # ShipStation appears to be recording their timestamps in local (PST) time but storing that timestamp
  # as UTC (so it's basically 7-8 hours off the correct time (depending on daylight savings). To compensate
  # for this the timestamp we use for "since" should be adjusted accordingly.
  ZONE = "Pacific Time (US & Canada)"

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

  post '/update_order_hold_date' do
    order = @payload[:shipment] || @payload[:order]
    options = {
      headers: ship_headers.merge("content-type" => "application/json"),
      parameters: build_order_hold_date_payload(order).to_json
    }
    response = ShipstationClient.request :post, "Orders/HoldUntil", options
    result 200, "Order #{order[:shipstation_id]} updated with new hold date"
  end


  # Shipstation wants orders and then it creates shipments. This integration assumes the
  # shipments are already split and will just create "orders" that are identical to the
  # storefront concept of a shipment.
  post '/add_shipment' do
    response = add_order_or_shipment(@payload[:shipment])
    add_object :shipment, return_order
    result 200, "Shipment transmitted to ShipStation: #{response[:shipstation_id]}"
  end

  post '/add_order' do
    response = add_order_or_shipment(@payload[:order])
    add_object :order, response
    result 200, "Order transmitted to ShipStation: #{response[:shipstation_id]}"
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
    current_page = (@config['page'] || 1).to_i

    query_string = "page=#{current_page}&pageSize=500&createDateStart=#{since_time_formatted}&sortBy=createDate"

    response = ShipstationClient.request :get, "shipments?#{query_string}", headers: ship_headers

    shipments = response.body["shipments"]

    shipments.each do |shipment|
      shipTo = shipment["shipTo"]
      add_object :shipment, {
        id: shipment["orderNumber"].strip,
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

    added_count = shipments.count

    if added_count == 0
      result 200
    elsif current_page < response.body['pages'].to_i
      add_parameter 'page', current_page + 1

      result 206, "Retrieved #{added_count} shipments from ShipStation"
    else
      Time.zone = ZONE
      new_since = Time.zone.parse(shipments.last['createDate']) + 1.second
      add_parameter 'since', new_since.utc.iso8601
      add_parameter 'page', 1

      result 200, "Retrieved #{added_count} shipments from ShipStation"
    end
  end

  private

  def add_order_or_shipment(order_or_shipment)
    order = populate_order(order_or_shipment)
    options = {
      headers: ship_headers.merge("content-type" => "application/json"),
      parameters: order.to_json
    }

    response = ShipstationClient.request :post, "Orders/CreateOrder", options
    order_or_shipment[:shipstation_id] = response.body["orderId"]
    order_or_shipment[:orderKey] = response.body["orderKey"]

    order_or_shipment
  end

  def since_time
    Time.zone = ZONE
    Time.zone.parse(@config[:since])
  end

  def since_time_formatted
    datetime = since_time
    datetime.strftime("%Y-%m-%d %H:%M:%S")
  end

  def hold_until_date_formatted(order)
    Time.zone = ZONE
    hold_time = Time.zone.parse(order[:hold_until_date])
    hold_time.strftime("%Y-%m-%d")
  end

  def build_order_hold_date_payload(order)
    {
      orderId: order[:shipstation_id],
      holdUntilDate: hold_until_date_formatted(order)
    }
  end

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
      "customerNotes" => shipment[:delivery_instructions],
      "internalNotes" => shipment[:internal_notes],
      "gift" => shipment[:is_gift],
      "packageCode" => 'package',
      "advancedOptions" => populate_advanced(shipment),
      "items" => populate_items(shipment[:items])
    }

    if shipment[:orderKey]
      order["orderKey"] = shipment[:orderKey]
    end

    if shipment[:ship_by_date]
      order["shipByDate"] = shipment[:ship_by_date]
    end

    if shipment[:amount_paid]
      order["amountPaid"] = shipment[:amount_paid].to_f.to_s
    end

    if shipment[:shipping_amount]
      order["shippingAmount"] = shipment[:shipping_amount].to_f.to_s
    end

    if shipment[:tax_amount]
      order["taxAmount"] = shipment[:tax_amount].to_f.to_s
    end

    if shipment[:gift_message]
      order["giftMessage"] = shipment[:gift_message]
    end

    if shipment[:confirmation]
      order["confirmation"] = map_confirmation(shipment[:confirmation])
    end

    if shipment[:requested_shipping_service]
      order["requestedShippingService"] = shipment[:requested_shipping_service]
    elsif shipment[:shipping_carrier]
      carrier_code = map_carrier(shipment[:shipping_carrier])
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
        "quantity" => item[:quantity].try(:to_i),
        "unitPrice" => item[:price].try(:to_f)
      }
    end
  end

  def populate_address(address)
    return if address.nil? || address.empty?
    address_hash = {
      :name => "#{address[:firstname]} #{address[:lastname]}", #required
      :street1 => address[:address1], #required
      :street2 => address[:address2],
      :street3 => address[:address3],
      :city => address[:city], #required
      :state => address[:state], #required
      :postalCode => address[:zipcode], #required
      :country => address[:country], #required
      :phone => address[:phone],
      :company => address[:company]
    }
    if address[:is_residential].present?
      address_hash[:residential] = address[:is_residential]
    end

    address_hash
  end

  def map_status(status)
    case status
    when 'hold'
      'on_hold'
    when 'canceled', 'cancelled'
      'cancelled'
    when 'awaiting_payment'
      'awaiting_payment'
    else
      'awaiting_shipment'
    end
  end

  def map_confirmation(confirmation)
    case confirmation
    when 'Delivery'
      'delivery'
    when 'Signature'
      'signature'
    when 'Adult Signature'
      'adult_signature'
    end
  end

  def ship_headers
    # the parameter authorization is for old customers - legacy support (Mashape)
    # new customers should use key & secret
    if !@config[:key].to_s.empty? && !@config[:secret].to_s.empty?
      authorization = Base64.strict_encode64("#{@config[:key]}:#{@config[:secret]}")
    else
      authorization = @config[:authorization]
    end

    headers = { 'Authorization' => "Basic #{authorization}" }

    unless @config[:x_partner].to_s.empty?
      headers['x-partner'] = @config[:x_partner]
    end

    headers
  end
end
