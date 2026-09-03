class HookPolicy < ApplicationPolicy
  def index?
    @account_user.administrator?
  end

  def create?
    @account_user.administrator?
  end

  def update?
    @account_user.administrator?
  end

  def process_event?
    true
  end

  def test?
    @account_user.administrator?
  end

  def destroy?
    @account_user.administrator?
  end
end
