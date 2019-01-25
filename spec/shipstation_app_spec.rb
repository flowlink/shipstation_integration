require 'spec_helper'

describe ShipStationApp do
  def json_response
    JSON.parse(last_response.body)
  end

  let(:config) do
    {
      "key" => ENV['SHIPSTATION_KEY'],
      "secret" => ENV['SHIPSTATION_SECRET']
    }
  end

  it "roots fine" do
    get "/" do
      expect(last_response.body).to match /ok/i
      expect(last_response.status).to eq 200
    end
  end

  describe 'POST /get_shipments' do
    let(:request) do
      {
        request_id: '1234567',
        parameters: config.merge(since: "2014-11-29T00:38:23Z")
      }
    end

    it 'returns shipments' do
      VCR.use_cassette("get_shipments/1414086620") do
        post '/get_shipments', request.to_json, {}
      end

      expect(json_response["summary"]).to match "Retrieved"
      expect(json_response["shipments"].count).to be >= 1
      expect(json_response["shipments"][0]["id"]).to be_present

      expect(last_response.status).to eq 200
    end

    it "doesnt set summary if no shipments found" do
      response = double("Response", code: 200, body: { "shipments" => [] }).as_null_object
      expect(Unirest).to receive(:get).and_return response

      post '/get_shipments', request.to_json, {}
      expect(json_response["summary"]).to be_nil
      expect(last_response.status).to eq 200
    end
  end

  describe 'POST /add_shipment' do
    let(:id) { "4325435345345" }

    let(:request) do
      {
        request_id: '123',
        parameters: config,
        shipment: {
          id: "#{id}",
          shipping_address: {
            firstname: "Bruno",
            lastname: "Buccolo",
            address1: "Rua Canario, 183",
            address2: "",
            zipcode: "01155-030",
            city: "São Paulo",
            state: "SP",
            country: "BR",
            phone: "5511955111091",
            company: "Spree Commerce",
            is_residential: true
          },
          items: [{
              name: "Spree T-Shirt",
              product_id: "SPREE-T-SHIRT",
              quantity: 9,
              price: 9,
              options: {}
          }],
          shipping_carrier: "Stamps.com",
          shipping_method: "USPS First Class Mail",
          created_at: "2014-06-02T15:38:23Z"
        }
      }
    end

    it 'creates a shipment with a requested_shipping_service' do
      VCR.use_cassette("add_shipment/#{id}") do
        post '/add_shipment', request.to_json, {}
      end

      expect(json_response["summary"]).to match "Shipment transmitted to ShipStation"
      expect(last_response.status).to eq 200
    end
  end

  describe 'POST /update_shipment' do
    let(:id) { "4325435345345" }

    let(:request) do
      {
        request_id: '123',
        parameters: config,
        shipment: {
          id: id,
          shipping_address: {
            firstname: "Brunow",
            lastname: "Buccolo",
            address1: "Rua Canario, 183",
            address2: "",
            zipcode: "01155-030",
            city: "São Paulo",
            state: "SP",
            country: "BR",
            phone: "5511955111091"
          },
          items: [{
              name: "Spree T-Shirt",
              product_id: "SPREE-T-SHIRT",
              quantity: 10,
              price: 9,
              options: {}
          }],
          shipping_carrier: "Stamps.com",
          shipping_method: "USPS First Class Mail",
          created_at: "2014-06-02T15:38:23Z"
        }
      }
    end

    it 'updates a shipment' do
      VCR.use_cassette("update_shipment/#{id}") do
        post '/update_shipment', request.to_json, {}
      end

      expect(json_response["summary"]).to match "Shipment update transmitted in ShipStation:"
      expect(last_response.status).to eq 200
    end

    it "test when shipment not found" do
      id = "3241234242342435432534"
      request[:shipment][:id] = id

      VCR.use_cassette("update_shipment/#{id}") do
        post '/update_shipment', request.to_json, {}
        expect(json_response["summary"]).to match "not found in ShipStation"
        expect(last_response.status).to eq 200
      end
    end
  end

  it "handles wrong credentials errors" do
    request = { parameters: config.merge(since: "2014-10-23T00:38:23Z") }
    request[:parameters][:key] = "wrong"

    VCR.use_cassette("wrong_key") do
      post '/get_shipments', request.to_json, {}
      expect(json_response["summary"]).to match ", API error:"
      expect(last_response.status).to eq 500
    end
  end

  it "handles invalid order object" do
    request = {
      parameters: config,
      shipment: {
        shipping_address: {},
        items: [],
        shipping_carrier: "Stamps.com",
        shipping_method: "USPS First Class Mail",
      }
    }

    VCR.use_cassette("invalid_object") do
      post '/add_shipment', request.to_json, {}
      expect(json_response["summary"]).to match ", API error:"
      expect(last_response.status).to eq 500
    end
  end
end
