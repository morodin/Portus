require "rails_helper"

class LdapMockAdapter
  attr_accessor :opts

  def initialize(o)
    @opts = o
  end

  def bind_as(_)
    true
  end
end

class LdapFailedBindAdapter < LdapMockAdapter
  def bind_as(_)
    false
  end
end

class LdapSearchAdapter
  def initialize(opts)
    @opts = opts
  end

  def search(_)
    @opts
  end
end

class LdapOriginal < Portus::LDAP
  def adapter
    super
  end
end

class LdapMock < Portus::LDAP
  attr_reader :params, :user, :last_symbol
  attr_accessor :bind_result

  def initialize(params)
    @params = { user: params }
    @bind_result = true
    @last_symbol = :ok
  end

  def load_configuration_test
    load_configuration
  end

  def bind_options_test
    bind_options
  end

  def find_or_create_user_test!
    find_or_create_user!
  end

  def generate_random_name_test(name)
    generate_random_name(name)
  end

  def success!(user)
    @user = user
  end

  def fail!(symbol)
    @last_symbol = symbol
  end

  def guess_email_test(response)
    @ldap = LdapSearchAdapter.new(response)
    guess_email
  end

  alias_method :fail, :fail!

  protected

  def adapter
    @bind_result ? LdapMockAdapter : LdapFailedBindAdapter
  end
end

class PortusMock < Portus::LDAP
  attr_reader :params

  def initialize(params)
    @params = params
  end

  def load_configuration_test
    load_configuration
  end
end

describe Portus::LDAP do
  let(:ldap_config) do
    {
      "enabled"  => true,
      "hostname" => "hostname",
      "port"     => 389,
      "base"     => "ou=users,dc=example,dc=com"
    }
  end

  before :each do
    allow_any_instance_of(Portus::LDAP).to receive(:authenticate!).and_call_original
  end

  it "sets self.enabled? accordingly" do
    expect(Portus::LDAP.enabled?).to be_falsey

    APP_CONFIG["ldap"] = {}
    expect(Portus::LDAP.enabled?).to be_falsey

    APP_CONFIG["ldap"] = { "enabled" => "lala" }
    expect(Portus::LDAP.enabled?).to be_falsey

    APP_CONFIG["ldap"] = { "enabled" => false }
    expect(Portus::LDAP.enabled?).to be_falsey

    APP_CONFIG["ldap"] = { "enabled" => true }
    expect(Portus::LDAP.enabled?).to be true
  end

  # Let's make code coverage happy
  it "calls the right adapter" do
    ldap = LdapOriginal.new(nil)
    expect(ldap.adapter.to_s).to eq "Net::LDAP"
  end

  it "loads the configuration properly" do
    lm = LdapMock.new(nil)
    expect(lm.load_configuration_test).to be nil

    APP_CONFIG["ldap"] = { "enabled" => true }
    expect(lm.load_configuration_test).to be nil

    # The Portus user does not authenticate through LDAP.
    APP_CONFIG["ldap"] = ldap_config
    lm = PortusMock.new(account: "portus", password: "1234")
    expect(lm.load_configuration_test).to be nil

    lm = LdapMock.new(username: "name", password: "1234")
    cfg = lm.load_configuration_test

    expect(cfg).to_not be nil
    expect(cfg.opts[:host]).to eq "hostname"
    expect(cfg.opts[:port]).to eq 389
  end

  it "fetches the right bind options" do
    APP_CONFIG["ldap"] = { "enabled" => true, "base" => "" }
    lm = LdapMock.new(username: "name", password: "1234")
    opts = lm.bind_options_test
    expect(opts.size).to eq 2
    expect(opts[:filter]).to eq "(uid=name)"
    expect(opts[:password]).to eq "1234"

    APP_CONFIG["ldap"] = ldap_config
    opts = lm.bind_options_test
    expect(opts.size).to eq 3
    expect(opts[:filter]).to eq "(uid=name)"
    expect(opts[:password]).to eq "1234"
    expect(opts[:base]).to eq "ou=users,dc=example,dc=com"
  end

  describe "#find_or_create_user!" do
    before :each do
      APP_CONFIG["ldap"] = { "enabled" => true }
    end

    it "the ldap user could be located" do
      user = create(:user, ldap_name: "name")
      lm = LdapMock.new(username: "name", password: "1234")
      ret = lm.find_or_create_user_test!
      expect(ret.id).to eq user.id
    end

    it "creates a new ldap user" do
      lm = LdapMock.new(username: "name", password: "12341234")
      lm.find_or_create_user_test!

      expect(User.count).to eq 1
      expect(User.find_by(ldap_name: "name")).to_not be nil
    end

    it "creates a new ldap user even if it has weird characters" do
      lm = LdapMock.new(username: "name!o", password: "12341234")
      lm.find_or_create_user_test!

      expect(User.count).to eq 1
      user = User.find_by(ldap_name: "name!o")
      expect(user.username).to eq "nameo"
      expect(user.ldap_name).to eq "name!o"
      expect(user.admin?).to be_truthy
    end

    it "creates a new ldap user with a new username if it clashes" do
      create(:admin, username: "name")
      lm = LdapMock.new(username: "name", password: "12341234")
      lm.find_or_create_user_test!

      expect(User.count).to eq 2
      created = User.find_by(ldap_name: "name")
      expect(created.username).to_not eq "name"
      expect(created.username.start_with?("name")).to be_truthy
      expect(created.admin?).to be_falsey
    end
  end

  describe "#generate_random_name" do
    it "creates a random name" do
      lm = LdapMock.new(nil)
      name = lm.generate_random_name_test("name")
      expect(name).to_not eq "name"
      expect(name.start_with?("name")).to be_truthy
    end

    it "generates a name that is large enough" do
      lm = LdapMock.new(nil)
      name = lm.generate_random_name_test("n")
      expect(name).to_not eq "n"
      expect(name.start_with?("n")).to be_truthy
    end

    it "raises an exception if it fails" do
      # Let's make sure that there will be a clash.
      create(:user, username: "name")
      101.times do |i|
        create(:user, username: "name#{i}")
      end

      lm = LdapMock.new(nil)
      lm.generate_random_name_test("name")
      expect(lm.last_symbol).to be :random_generation_failed
    end
  end

  describe "#authenticate!" do
    it "raises an exception if ldap is not supported" do
      lm = LdapMock.new(username: "name", password: "1234")
      lm.authenticate!
      expect(lm.last_symbol).to be :ldap_failed
    end

    it "fails if the user couldn't bind" do
      APP_CONFIG["ldap"] = { "enabled" => true, "base" => "" }
      lm = LdapMock.new(username: "name", password: "12341234")
      lm.bind_result = false
      lm.authenticate!
      expect(lm.last_symbol).to be :ldap_bind_failed
    end

    it "raises an exception if the user could not created" do
      APP_CONFIG["ldap"] = { "enabled" => true, "base" => "" }
      lm = LdapMock.new(username: "", password: "1234")
      lm.authenticate!
      expect(lm.last_symbol).to be :invalid_username
    end

    it "returns a success if it was successful" do
      APP_CONFIG["ldap"] = { "enabled" => true, "base" => "" }
      lm = LdapMock.new(username: "name", password: "12341234")
      lm.authenticate!
      expect(lm.last_symbol).to be :ok
      expect(lm.user.username).to eq "name"
    end
  end

  describe "#guess_email" do
    let(:empty_dc) do
      [
        {
          "dn"    => ["ou=users"],
          "email" => "user@example.com"
        }
      ]
    end

    let(:multiple_dn) do
      [
        {
          "dn"    => ["ou=users,dc=example,dc=com", "ou=accounts,dc=example,dc=com"],
          "email" => "user@example.com"
        }
      ]
    end

    let(:valid_response) do
      [
        {
          "dn"    => ["ou=users,dc=example,dc=com"],
          "email" => "user@example.com"
        }
      ]
    end

    it "returns an empty email if disabled" do
      ge = { "enabled" => false, "attr" => "" }
      APP_CONFIG["ldap"] = { "enabled" => true, "base" => "", "guess_email" => ge }

      lm = LdapMock.new(username: "name", password: "12341234")
      expect(lm.guess_email_test(valid_response)).to eq ""
    end

    it "returns an empty email if no records have been found" do
      ge = { "enabled" => true, "attr" => "" }
      APP_CONFIG["ldap"] = { "enabled" => true, "base" => "", "guess_email" => ge }

      lm = LdapMock.new(username: "name", password: "12341234")
      expect(lm.guess_email_test([])).to eq ""
    end

    it "returns an empty email if more than one dn gets returned" do
      ge = { "enabled" => true, "attr" => "" }
      APP_CONFIG["ldap"] = { "enabled" => true, "base" => "", "guess_email" => ge }

      lm = LdapMock.new(username: "name", password: "12341234")
      expect(lm.guess_email_test(multiple_dn)).to eq ""
    end

    it "returns an empty email if the dc hostname could not be guessed" do
      ge = { "enabled" => true, "attr" => "" }
      APP_CONFIG["ldap"] = { "enabled" => true, "base" => "", "guess_email" => ge }

      lm = LdapMock.new(username: "name", password: "12341234")
      expect(lm.guess_email_test(empty_dc)).to eq ""
    end

    it "returns a valid email if the dc can be guessed" do
      ge = { "enabled" => true, "attr" => "" }
      APP_CONFIG["ldap"] = { "enabled" => true, "base" => "", "guess_email" => ge }

      lm = LdapMock.new(username: "name", password: "12341234")
      expect(lm.guess_email_test(valid_response)).to eq "name@example.com"
    end

    it "returns an email if the specified attribute does not exist" do
      ge = { "enabled" => true, "attr" => "non_existing" }
      APP_CONFIG["ldap"] = { "enabled" => true, "base" => "", "guess_email" => ge }

      lm = LdapMock.new(username: "name", password: "12341234")
      expect(lm.guess_email_test(valid_response)).to eq ""
    end

    it "returns a valid email if the given attribute exists" do
      ge = { "enabled" => true, "attr" => "email" }
      APP_CONFIG["ldap"] = { "enabled" => true, "base" => "", "guess_email" => ge }

      lm = LdapMock.new(username: "name", password: "12341234")
      expect(lm.guess_email_test(valid_response)).to eq "user@example.com"
    end
  end
end
